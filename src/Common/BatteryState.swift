//
//  BatteryState.swift
//  BatteryToolkit - Sailing Mode & Intelligent Battery Manager
//

import Foundation

public enum PowerSource: String, Codable, Sendable {
    case acAdapter = "AC Adapter"
    case battery = "Battery"
    case unknown = "Unknown"
}

public enum ChargingStatus: String, Codable, Sendable {
    case charging = "Charging"
    case sailing = "Sailing (AC Powered)"
    case discharging = "Discharging"
    case charged = "Full / At Limit"
    case paused = "Paused"
    case unsupported = "Hardware Unsupported"
}

public enum ChargingMode: String, Codable, Sendable {
    case sailing = "Sailing Mode"
    case directLimit = "Direct Limit Mode"
    case fullChargeOnce = "Charge to 100% (Once)"
    case manualHold = "Inhibit Charging (Manual)"
}

public struct BatterySnapshot: Codable, Sendable {
    public var percentage: Int
    public var isCharging: Bool
    public var isACConnected: Bool
    public var isChargeInhibited: Bool
    public var isPowerAdapterDisabled: Bool
    public var currentCapacity: Int
    public var maxCapacity: Int
    public var cycleCount: Int
    public var temperature: Double
    public var voltage: Double
    public var amperage: Int
    public var watts: Double
    public var systemLoadWatts: Double
    public var adapterWatts: Int
    public var timeRemainingMinutes: Int
    public var activeSMCKey: String
    public var architecture: String
    public var timestamp: Date

    public init(
        percentage: Int = 100,
        isCharging: Bool = false,
        isACConnected: Bool = true,
        isChargeInhibited: Bool = false,
        isPowerAdapterDisabled: Bool = false,
        currentCapacity: Int = 0,
        maxCapacity: Int = 0,
        cycleCount: Int = 0,
        temperature: Double = 25.0,
        voltage: Double = 12.0,
        amperage: Int = 0,
        watts: Double = 0.0,
        systemLoadWatts: Double = 0.0,
        adapterWatts: Int = 0,
        timeRemainingMinutes: Int = -1,
        activeSMCKey: String = "Apple Silicon PMU",
        architecture: String = "Apple Silicon",
        timestamp: Date = Date()
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isACConnected = isACConnected
        self.isChargeInhibited = isChargeInhibited
        self.isPowerAdapterDisabled = isPowerAdapterDisabled
        self.currentCapacity = currentCapacity
        self.maxCapacity = maxCapacity
        self.cycleCount = cycleCount
        self.temperature = temperature
        self.voltage = voltage
        self.amperage = amperage
        self.watts = watts
        self.systemLoadWatts = systemLoadWatts
        self.adapterWatts = adapterWatts
        self.timeRemainingMinutes = timeRemainingMinutes
        self.activeSMCKey = activeSMCKey
        self.architecture = architecture
        self.timestamp = timestamp
    }
}

public struct SailingSettings: Codable, Sendable {
    public var targetLimit: Int
    public var sailingDrop: Int
    public var sailingEnabled: Bool
    public var adapterSleepEnabled: Bool
    public var magSafeSyncEnabled: Bool
    public var launchAtLogin: Bool

    public var resumeThreshold: Int {
        return max(20, targetLimit - sailingDrop)
    }

    public init(
        targetLimit: Int = 85,
        sailingDrop: Int = 10,
        sailingEnabled: Bool = true,
        adapterSleepEnabled: Bool = false,
        magSafeSyncEnabled: Bool = true,
        launchAtLogin: Bool = true
    ) {
        self.targetLimit = targetLimit
        self.sailingDrop = sailingDrop
        self.sailingEnabled = sailingEnabled
        self.adapterSleepEnabled = adapterSleepEnabled
        self.magSafeSyncEnabled = magSafeSyncEnabled
        self.launchAtLogin = launchAtLogin
    }

    public static let `default` = SailingSettings()
}
