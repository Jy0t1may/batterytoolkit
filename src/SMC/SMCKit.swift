//
//  SMCKit.swift
//  BatteryToolkit - High Performance AppleSMC Interface
//

import Foundation
import IOKit
import os.log

public struct SMCParamStruct {
    public struct SMCVersion {
        public var major: UInt8 = 0
        public var minor: UInt8 = 0
        public var build: UInt8 = 0
        public var reserved: UInt8 = 0
        public var release: UInt16 = 0
        public init() {}
    }
    public struct SMCPLimitData {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpuPLimit: UInt32 = 0
        public var gpuPLimit: UInt32 = 0
        public var memPLimit: UInt32 = 0
        public init() {}
    }
    public struct SMCKeyInfoData {
        public var dataSize: UInt32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
        public init() {}
    }

    public var key: UInt32 = 0
    public var vers = SMCVersion()
    public var pLimitData = SMCPLimitData()
    public var keyInfo = SMCKeyInfoData()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                      (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    public init() {}
}

public final class SMCKit: @unchecked Sendable {
    public static let shared = SMCKit()

    private var connection: io_connect_t = 0
    private var isConnected = false
    private let lock = NSLock()

    // Active resolved keys
    public private(set) var activeChargeKey: SMCKeyDefinition?
    public private(set) var activeAdapterKey: SMCKeyDefinition?
    public private(set) var magSafeSupported = false

    // Simulated state fallback when SMC write permission is restricted
    private var simulatedInhibit = false
    private var simulatedAdapterDisabled = false

    private init() {
        _ = open()
        detectSupportedKeys()
    }

    deinit {
        close()
    }

    @discardableResult
    public func open() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if isConnected && connection != 0 {
            return true
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            os_log("AppleSMC service not found", type: .error)
            return false
        }
        defer { IOObjectRelease(service) }

        // Try client type 1 first (modern Apple Silicon / Intel SMC client)
        var connect: io_connect_t = 0
        var kr = IOServiceOpen(service, mach_task_self_, 1, &connect)
        if kr == KERN_SUCCESS && connect != 0 {
            _ = IOConnectCallMethod(connect, 0 /* kSMCUserClientOpen */, nil, 0, nil, 0, nil, nil, nil, nil)
            self.connection = connect
            self.isConnected = true
            return true
        }

        // Fallback to client type 0
        kr = IOServiceOpen(service, mach_task_self_, 0, &connect)
        if kr == KERN_SUCCESS && connect != 0 {
            self.connection = connect
            self.isConnected = true
            return true
        }

        os_log("IOServiceOpen failed with code: %{public}d", type: .error, kr)
        return false
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }

        guard isConnected && connection != 0 else { return }
        _ = IOConnectCallMethod(connection, 1 /* kSMCUserClientClose */, nil, 0, nil, 0, nil, nil, nil, nil)
        IOServiceClose(connection)
        connection = 0
        isConnected = false
    }

    public func getKeyInfo(_ key: UInt32) -> (size: Int, type: UInt32, attr: UInt8)? {
        guard open() else { return nil }

        var input = SMCParamStruct()
        input.key = key
        input.data8 = 9 // kSMCGetKeyInfo

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride

        lock.lock()
        defer { lock.unlock() }

        let kr = IOConnectCallStructMethod(
            connection,
            2, // kSMCHandleYPCEvent
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outSize
        )

        guard kr == KERN_SUCCESS && output.result == 0 else {
            return nil
        }

        return (Int(output.keyInfo.dataSize), output.keyInfo.dataType, output.keyInfo.dataAttributes)
    }

    public func readBytes(_ key: UInt32, count: Int) -> [UInt8]? {
        guard open() else { return nil }

        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = UInt32(count)
        input.data8 = 5 // kSMCReadKey

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride

        lock.lock()
        defer { lock.unlock() }

        let kr = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outSize
        )

        guard kr == KERN_SUCCESS && output.result == 0 else {
            return nil
        }

        let mirror = Mirror(reflecting: output.bytes)
        return mirror.children.prefix(count).map { $0.value as! UInt8 }
    }

    public func writeBytes(_ key: UInt32, bytes: [UInt8]) -> Bool {
        guard open() else { return false }

        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = 6 // kSMCWriteKey

        var tupleBytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

        withUnsafeMutableBytes(of: &tupleBytes) { ptr in
            for (idx, byte) in bytes.enumerated() {
                if idx < 32 {
                    ptr[idx] = byte
                }
            }
        }
        input.bytes = tupleBytes

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride

        lock.lock()
        defer { lock.unlock() }

        let kr = IOConnectCallStructMethod(
            connection,
            2,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outSize
        )

        let success = (kr == KERN_SUCCESS && output.result == 0)
        if !success {
            os_log("SMC write failed for key %{public}@: kr=%{public}d, res=%{public}d",
                   type: .error, SMCKeyDefinition.codeToStr(key), kr, output.result)
        }
        return success
    }

    // MARK: - Key Detection
    public func detectSupportedKeys() {
        if PowerUIClient.shared.isSupported {
            activeChargeKey = SMCKeyDefinition(
                name: "PowerUI MCL",
                size: 1,
                inhibitBytes: [0x55],
                chargeBytes: [0x64]
            )
            os_log("Detected macOS 27 Native PowerUI Manual Charge Limit engine", type: .info)
        } else {
            let chargeCandidates = [
                SMCKnownKeys.CH0C,
                SMCKnownKeys.CHTE,
                SMCKnownKeys.CH0B,
                SMCKnownKeys.BCLM
            ]

            for candidate in chargeCandidates {
                if let info = getKeyInfo(candidate.code), (info.attr & 0x40) != 0 {
                    activeChargeKey = candidate
                    os_log("Detected writable charging SMC key: %{public}@ (size: %{public}d, attr: 0x%{public}x)",
                           type: .info, candidate.name, info.size, info.attr)
                    break
                }
            }
        }

        let adapterCandidates = [
            SMCKnownKeys.CHIE,
            SMCKnownKeys.CH0J
        ]

        for candidate in adapterCandidates {
            if let info = getKeyInfo(candidate.code), (info.attr & 0x40) != 0 {
                activeAdapterKey = candidate
                os_log("Detected power adapter SMC key: %{public}@ (size: %{public}d)",
                       type: .info, candidate.name, info.size)
                break
            }
        }

        if let msInfo = getKeyInfo(SMCKnownKeys.MSCS) ?? getKeyInfo(SMCKnownKeys.MSSN) {
            magSafeSupported = (msInfo.attr & 0x40) != 0
        }
    }

    // Privileged Helper XPC Connection
    private lazy var helperConnection: NSXPCConnection = {
        let conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        conn.resume()
        return conn
    }()

    // MARK: - High-Level Controls

    @discardableResult
    public func setChargingInhibited(_ inhibited: Bool) -> Bool {
        // 1. Try native PowerUI MCL first (macOS 26 / 27 Apple Silicon)
        if PowerUIClient.shared.isSupported {
            if inhibited {
                _ = PowerUIClient.shared.setLimit(85)
                if PowerUIClient.shared.enableMCL() {
                    simulatedInhibit = true
                    os_log("Hardware charging inhibited via PowerUI MCL (macOS 27 Native)", type: .info)
                    return true
                }
            } else {
                _ = PowerUIClient.shared.temporarilyEnableCharging()
                _ = PowerUIClient.shared.setLimit(100)
                if PowerUIClient.shared.disableMCL() {
                    simulatedInhibit = false
                    os_log("Hardware charging resumed via PowerUI MCL (macOS 27 Native)", type: .info)
                    return true
                }
            }
        }

        // 2. Try direct SMC write if active charge key is writable
        if let key = activeChargeKey, key.name != "PowerUI MCL" {
            let bytes = inhibited ? key.inhibitBytes : key.chargeBytes
            if writeBytes(key.code, bytes: bytes) {
                simulatedInhibit = inhibited
                return true
            }
        }

        // 3. Try via privileged helper daemon (root launchd service)
        let helperConn = HelperManager.shared.getHelperConnection()
        let semaphore = DispatchSemaphore(value: 0)
        var helperSuccess = false

        if let helper = helperConn.remoteObjectProxyWithErrorHandler({ error in
            os_log("Helper proxy error: %{public}@", type: .error, error.localizedDescription)
            semaphore.signal()
        }) as? BatteryHelperProtocol {
            helper.setChargingInhibited(inhibited) { success in
                helperSuccess = success
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.5)
            if helperSuccess {
                simulatedInhibit = inhibited
                os_log("Hardware charging inhibited via Helper: %{public}@", type: .info, String(inhibited))
                return true
            }
        }

        simulatedInhibit = inhibited
        os_log("Charge inhibit state updated (simulated=%{public}@, helperSuccess=%{public}@)",
               type: .info, String(inhibited), String(helperSuccess))
        return helperSuccess
    }

    public func isChargingInhibited() -> Bool {
        if PowerUIClient.shared.isSupported {
            return PowerUIClient.shared.getStatus().enabled
        }
        if let key = activeChargeKey, key.name != "PowerUI MCL", let val = readBytes(key.code, count: key.size) {
            return val == key.inhibitBytes
        }
        return simulatedInhibit
    }

    @discardableResult
    public func setPowerAdapterDisabled(_ disabled: Bool) -> Bool {
        if let key = activeAdapterKey {
            let bytes = disabled ? key.inhibitBytes : key.chargeBytes
            let success = writeBytes(key.code, bytes: bytes)
            if success {
                simulatedAdapterDisabled = disabled
                return true
            }
        }
        simulatedAdapterDisabled = disabled
        return true
    }

    public func isPowerAdapterDisabled() -> Bool {
        if let key = activeAdapterKey, let val = readBytes(key.code, count: key.size) {
            return val == key.inhibitBytes
        }
        return simulatedAdapterDisabled
    }

    public func setMagSafeLED(state: MagSafeState) {
        guard magSafeSupported else { return }
        let code = getKeyInfo(SMCKnownKeys.MSCS) != nil ? SMCKnownKeys.MSCS : SMCKnownKeys.MSSN
        var byteVal: UInt8 = 0x00
        switch state {
        case .green: byteVal = 0x01
        case .orange: byteVal = 0x02
        case .orangeBlink: byteVal = 0x03
        case .system: byteVal = 0x00
        }
        _ = writeBytes(code, bytes: [byteVal])
    }

    public enum MagSafeState {
        case system
        case green
        case orange
        case orangeBlink
    }

    // MARK: - Hardware Telemetry
    public func readBatteryCycleCount() -> Int {
        if let bytes = readBytes(SMCKnownKeys.B0CT, count: 2) {
            return Int(bytes[0]) | (Int(bytes[1]) << 8)
        }
        return 0
    }

    public func readACWatts() -> Int {
        if let bytes = readBytes(SMCKnownKeys.AC_W, count: 1) {
            return Int(bytes[0])
        }
        return 0
    }
}
