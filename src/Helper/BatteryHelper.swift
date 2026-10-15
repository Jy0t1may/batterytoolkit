//
//  BatteryHelper.swift
//  BatteryToolkit - Privileged Helper Implementation
//

import Foundation
import os.log

public final class BatteryHelper: NSObject, BatteryHelperProtocol {
    public static let shared = BatteryHelper()

    public func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.helperVersion)
    }

    public func setChargingInhibited(_ inhibited: Bool, withReply reply: @escaping (Bool) -> Void) {
        let success = SMCKit.shared.setChargingInhibited(inhibited)
        os_log("Helper setChargingInhibited: %{public}@ -> result: %{public}@",
               type: .info, String(inhibited), String(success))
        reply(success)
    }

    public func setPowerAdapterDisabled(_ disabled: Bool, withReply reply: @escaping (Bool) -> Void) {
        let success = SMCKit.shared.setPowerAdapterDisabled(disabled)
        os_log("Helper setPowerAdapterDisabled: %{public}@ -> result: %{public}@",
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
