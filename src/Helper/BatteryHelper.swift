//
//  BatteryHelper.swift
//  BatteryToolkit - Privileged Helper Implementation
//

import Foundation
import IOKit.pwr_mgt
import os.log

public final class BatteryHelper: NSObject, BatteryHelperProtocol {
    public static let shared = BatteryHelper()

    private var currentInhibitState: Bool? = nil
    private var openAssertions = Set<IOPMAssertionID>()
    private let stateLock = NSLock()

    public func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.helperVersion)
    }

    public func setChargingInhibited(_ inhibited: Bool, limit: Int, withReply reply: @escaping (Bool) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        var success = false

        // 1. Apple Silicon Native PMU Bypass (Desktop Mode)
        // This keeps the Mac running directly on AC power (amperage = 0 mA)
        // without charging or drawing from battery.
        if PowerUIClient.shared.isSupported {
            if inhibited {
                let validLimits = [80, 85, 90, 95, 100]
                let target = validLimits.filter { $0 <= limit }.last ?? 80
                _ = PowerUIClient.shared.setLimit(target)
                if PowerUIClient.shared.enableMCL() {
                    success = true
                }
            } else {
                _ = PowerUIClient.shared.temporarilyEnableCharging()
                _ = PowerUIClient.shared.setLimit(100)
                if PowerUIClient.shared.disableMCL() {
                    success = true
                }
            }
        }

        // 2. Direct SMC charging control registers (Intel / Legacy Apple Silicon)
        let ch0cCode = SMCKeyDefinition.strToCode("CH0C")
        if SMCKit.shared.getKeyInfo(ch0cCode) != nil {
            let byte: UInt8 = inhibited ? 0x01 : 0x00
            if SMCKit.shared.writeBytes(ch0cCode, bytes: [byte]) { success = true }
        }

        let ch0bCode = SMCKeyDefinition.strToCode("CH0B")
        if SMCKit.shared.getKeyInfo(ch0bCode) != nil {
            let byte: UInt8 = inhibited ? 0x02 : 0x00
            if SMCKit.shared.writeBytes(ch0bCode, bytes: [byte]) { success = true }
        }

        let chteCode = SMCKeyDefinition.strToCode("CHTE")
        if SMCKit.shared.getKeyInfo(chteCode) != nil {
            let bytes: [UInt8] = inhibited ? [0x01, 0x00, 0x00, 0x00] : [0x00, 0x00, 0x00, 0x00]
            if SMCKit.shared.writeBytes(chteCode, bytes: bytes) { success = true }
        }

        let bclmCode = SMCKeyDefinition.strToCode("BCLM")
        if SMCKit.shared.getKeyInfo(bclmCode) != nil {
            let byte: UInt8 = inhibited ? UInt8(max(50, min(100, limit))) : 100
            if SMCKit.shared.writeBytes(bclmCode, bytes: [byte]) { success = true }
        }

        currentInhibitState = inhibited
        os_log("BatteryHelper setChargingInhibited: inhibited=%{public}@ limit=%{public}d -> result: %{public}@",
               type: .info, String(inhibited), limit, String(success))
        reply(success)
    }

    public func setPowerAdapterDisabled(_ disabled: Bool, withReply reply: @escaping (Bool) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        var success = false
        let chieCode = SMCKeyDefinition.strToCode("CHIE")
        if SMCKit.shared.getKeyInfo(chieCode) != nil {
            let byte: UInt8 = disabled ? 0x08 : 0x00
            success = SMCKit.shared.writeBytes(chieCode, bytes: [byte])
        }
        os_log("BatteryHelper setPowerAdapterDisabled: %{public}@ -> result: %{public}@",
               type: .info, String(disabled), String(success))
        reply(success)
    }

    public func writeSMCByte(key: String, value: UInt8, withReply reply: @escaping (Bool) -> Void) {
        let code = SMCKeyDefinition.strToCode(key)
        let success = SMCKit.shared.writeBytes(code, bytes: [value])
        reply(success)
    }

    public func readSMCByte(key: String, withReply reply: @escaping (UInt8) -> Void) {
        let code = SMCKeyDefinition.strToCode(key)
        if let bytes = SMCKit.shared.readBytes(code, count: 1), let first = bytes.first {
            reply(first)
        } else {
            reply(0)
        }
    }

    // MARK: - Root Sleep Assertion Management (AlDente Model)

    public func createAssertion(type: String, reason: String, withReply reply: @escaping (UInt32) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        var assertionID: IOPMAssertionID = 0
        let cfType = type as CFString
        let cfReason = reason as CFString

        let kr = IOPMAssertionCreateWithName(
            cfType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            cfReason,
            &assertionID
        )

        if kr == kIOReturnSuccess {
            openAssertions.insert(assertionID)
            os_log("BatteryHelper created sleep assertion: %{public}u for reason '%{public}@'",
                   type: .info, assertionID, reason)
            reply(UInt32(assertionID))
        } else {
            os_log("BatteryHelper failed to create assertion: code %{public}d", type: .error, kr)
            reply(0)
        }
    }

    public func releaseAssertion(id: UInt32, withReply reply: @escaping (Bool) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let assertionID = IOPMAssertionID(id)
        if openAssertions.contains(assertionID) {
            let kr = IOPMAssertionRelease(assertionID)
            openAssertions.remove(assertionID)
            os_log("BatteryHelper released sleep assertion: %{public}u (kr=%{public}d)",
                   type: .info, assertionID, kr)
            reply(kr == kIOReturnSuccess)
        } else {
            reply(true)
        }
    }

    public func resetDefaults(withReply reply: @escaping (Bool) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        os_log("BatteryHelper resetDefaults triggered (watchdog cleanup)", type: .info)

        // 1. Release all open assertions
        for assertionID in openAssertions {
            IOPMAssertionRelease(assertionID)
        }
        openAssertions.removeAll()

        // 2. Restore power adapter
        let chieCode = SMCKeyDefinition.strToCode("CHIE")
        if SMCKit.shared.getKeyInfo(chieCode) != nil {
            _ = SMCKit.shared.writeBytes(chieCode, bytes: [0x00])
        }

        // 3. Restore charging
        if PowerUIClient.shared.isSupported {
            _ = PowerUIClient.shared.temporarilyEnableCharging()
            _ = PowerUIClient.shared.setLimit(100)
            _ = PowerUIClient.shared.disableMCL()
        }

        let ch0cCode = SMCKeyDefinition.strToCode("CH0C")
        if SMCKit.shared.getKeyInfo(ch0cCode) != nil {
            _ = SMCKit.shared.writeBytes(ch0cCode, bytes: [0x00])
        }

        let ch0bCode = SMCKeyDefinition.strToCode("CH0B")
        if SMCKit.shared.getKeyInfo(ch0bCode) != nil {
            _ = SMCKit.shared.writeBytes(ch0bCode, bytes: [0x00])
        }

        let chteCode = SMCKeyDefinition.strToCode("CHTE")
        if SMCKit.shared.getKeyInfo(chteCode) != nil {
            _ = SMCKit.shared.writeBytes(chteCode, bytes: [0x00, 0x00, 0x00, 0x00])
        }

        currentInhibitState = false
        reply(true)
    }
}
