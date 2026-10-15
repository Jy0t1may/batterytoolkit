//
//  SMCKeys.swift
//  BatteryToolkit - SMC Keys & Protocol Definitions
//

import Foundation

public struct SMCKeyDefinition: Sendable {
    public let name: String
    public let code: UInt32
    public let size: Int
    public let inhibitBytes: [UInt8]
    public let chargeBytes: [UInt8]

    public init(name: String, size: Int, inhibitBytes: [UInt8], chargeBytes: [UInt8]) {
        self.name = name
        self.size = size
        self.inhibitBytes = inhibitBytes
        self.chargeBytes = chargeBytes
        self.code = SMCKeyDefinition.strToCode(name)
    }

    public static func strToCode(_ str: String) -> UInt32 {
        var total: UInt32 = 0
        for byte in str.utf8.prefix(4) {
            total = (total << 8) | UInt32(byte)
        }
        return total
    }

    public static func codeToStr(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

public enum SMCKnownKeys {
    // Charge Inhibit Candidates
    public static let CH0B = SMCKeyDefinition(
        name: "CH0B",
        size: 1,
        inhibitBytes: [0x02],
        chargeBytes: [0x00]
    )
    public static let CH0C = SMCKeyDefinition(
        name: "CH0C",
        size: 1,
        inhibitBytes: [0x01],
        chargeBytes: [0x00]
    )
    public static let CHTE = SMCKeyDefinition(
        name: "CHTE",
        size: 4,
        inhibitBytes: [0x01, 0x00, 0x00, 0x00],
        chargeBytes: [0x00, 0x00, 0x00, 0x00]
    )
    public static let BCLM = SMCKeyDefinition(
        name: "BCLM",
        size: 1,
        inhibitBytes: [0x55], // 85% by default
        chargeBytes: [0x64]  // 100%
    )

    // Adapter Inhibit Candidates
    public static let CHIE = SMCKeyDefinition(
        name: "CHIE",
        size: 1,
        inhibitBytes: [0x08], // Adapter off
        chargeBytes: [0x00]   // Adapter on
    )
    public static let CH0J = SMCKeyDefinition(
        name: "CH0J",
        size: 1,
        inhibitBytes: [0x20],
        chargeBytes: [0x00]
    )

    // MagSafe Keys
    public static let MSCS = SMCKeyDefinition.strToCode("MSCS")
    public static let MSSN = SMCKeyDefinition.strToCode("MSSN")

    // Battery / Power Telemetry
    public static let B0CT = SMCKeyDefinition.strToCode("B0CT") // Cycle Count (ui16)
    public static let B0RM = SMCKeyDefinition.strToCode("B0RM") // Remaining Capacity (ui16)
    public static let B0FC = SMCKeyDefinition.strToCode("B0FC") // Full Capacity (ui16)
    public static let BRSC = SMCKeyDefinition.strToCode("BRSC") // Battery Remaining State of Charge (ui8)
    public static let BATP = SMCKeyDefinition.strToCode("BATP") // Battery Powered Flag (flag)
    public static let BSIn = SMCKeyDefinition.strToCode("BSIn") // Battery Status Info (ui8)
    public static let AC_W = SMCKeyDefinition.strToCode("AC-W") // AC Watts
}
