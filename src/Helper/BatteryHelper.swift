//
//  BatteryHelper.swift
//  BatteryToolkit - Privileged Helper Implementation
//

import Foundation
import os.log

public final class BatteryHelper: NSObject, BatteryHelperProtocol {
    public static let shared = BatteryHelper()

    private var currentInhibitState: Bool? = nil
    private let stateLock = NSLock()

    public func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.helperVersion)
    }

    public func setChargingInhibited(_ inhibited: Bool, withReply reply: @escaping (Bool) -> Void) {
        stateLock.lock()
        // If the hardware is already in the requested state, return true
        if let current = currentInhibitState, current == inhibited {
            stateLock.unlock()
            reply(true)
            return
        }

        var success = false

        // 1. Primary Engine: PowerUI Manual Charge Limit (macOS 26 / 27 Native PMU)
        if PowerUIClient.shared.isSupported {
            if inhibited {
                _ = PowerUIClient.shared.setLimit(85)
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

        // 2. Direct SMC charging control registers (Intel / legacy Apple Silicon)
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

        currentInhibitState = inhibited
        stateLock.unlock()

        os_log("BatteryHelper setChargingInhibited: %{public}@ -> result: %{public}@",
               type: .info, String(inhibited), String(success))
        reply(success)
    }

    public func setPowerAdapterDisabled(_ disabled: Bool, withReply reply: @escaping (Bool) -> Void) {
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
}
