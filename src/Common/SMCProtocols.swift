//
//  SMCProtocols.swift
//  BatteryToolkit - XPC Interface Protocols
//

import Foundation

@objc(BatteryHelperProtocol)
public protocol BatteryHelperProtocol {
    func getVersion(withReply reply: @escaping (String) -> Void)
    func setChargingInhibited(_ inhibited: Bool, limit: Int, withReply reply: @escaping (Bool) -> Void)
    func setPowerAdapterDisabled(_ disabled: Bool, withReply reply: @escaping (Bool) -> Void)
    func writeSMCByte(key: String, value: UInt8, withReply reply: @escaping (Bool) -> Void)
    func readSMCByte(key: String, withReply reply: @escaping (UInt8) -> Void)
    func createAssertion(type: String, reason: String, withReply reply: @escaping (UInt32) -> Void)
    func releaseAssertion(id: UInt32, withReply reply: @escaping (Bool) -> Void)
    func resetDefaults(withReply reply: @escaping (Bool) -> Void)
}

public enum HelperConstants {
    public static let machServiceName = "me.batterytoolkit.helper.mach"
    public static let helperID = "me.batterytoolkit.helper"
    public static let helperVersion = "2.1.0"
}
