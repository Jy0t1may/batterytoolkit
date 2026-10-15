//
//  SMCProtocols.swift
//  BatteryToolkit - XPC Interface Protocols
//

import Foundation

@objc(BatteryHelperProtocol)
public protocol BatteryHelperProtocol {
    func getVersion(withReply reply: @escaping (String) -> Void)
    func setChargingInhibited(_ inhibited: Bool, withReply reply: @escaping (Bool) -> Void)
    func setPowerAdapterDisabled(_ disabled: Bool, withReply reply: @escaping (Bool) -> Void)
    func writeSMCByte(key: String, value: UInt8, withReply reply: @escaping (Bool) -> Void)
    func readSMCByte(key: String, withReply reply: @escaping (UInt8) -> Void)
}

public enum HelperConstants {
    public static let machServiceName = "me.batterytoolkit.helper.mach"
    public static let helperID = "me.batterytoolkit.helper"
    public static let helperVersion = "2.0.0"
}
