//
//  PowerMonitor.swift
//  BatteryToolkit - Real-time IOKit & AppleSmartBattery Power Monitor
//

import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import notify
import os.log

public final class PowerMonitor: @unchecked Sendable {
    public static let shared = PowerMonitor()

    public typealias PowerCallback = @Sendable (BatterySnapshot) -> Void
    public var onPowerStateChanged: PowerCallback?

    private var powerToken: Int32 = 0
    private var percentToken: Int32 = 0
    private var isListening = false
    private let lock = NSLock()

    private let cachedArch: String = {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelStr = String(cString: model)
        return modelStr.isEmpty ? "Mac" : modelStr
    }()

    private init() {}

    public func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        guard !isListening else { return }

        // Register for power source change notifications
        notify_register_dispatch(
            kIOPSNotifyPowerSource,
            &powerToken,
            DispatchQueue.main
        ) { [weak self] _ in
            self?.handlePowerChange()
        }

        // Register for battery percentage notifications
        notify_register_dispatch(
            "com.apple.system.powersources.percent",
            &percentToken,
            DispatchQueue.main
        ) { [weak self] _ in
            self?.handlePowerChange()
        }

        isListening = true
        handlePowerChange()
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        guard isListening else { return }
        notify_cancel(powerToken)
        notify_cancel(percentToken)
        isListening = false
    }

    public func getCurrentSnapshot() -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.architecture = self.cachedArch

        // 1. Query IOKit Power Sources API
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }

                if let isPresent = desc[kIOPSIsPresentKey] as? Bool, !isPresent {
                    continue
                }

                if let state = desc[kIOPSPowerSourceStateKey] as? String {
                    snapshot.isACConnected = (state == kIOPSACPowerValue)
                }

                if let isCharging = desc[kIOPSIsChargingKey] as? Bool {
                    snapshot.isCharging = isCharging
                }

                if let currentCap = desc[kIOPSCurrentCapacityKey] as? Int {
                    snapshot.currentCapacity = currentCap
                }

                if let maxCap = desc[kIOPSMaxCapacityKey] as? Int {
                    snapshot.maxCapacity = maxCap
                    if maxCap > 0 {
                        snapshot.percentage = Int((Double(snapshot.currentCapacity) / Double(maxCap)) * 100.0)
                    }
                }

                if let timeRemaining = desc[kIOPSTimeToEmptyKey] as? Int {
                    snapshot.timeRemainingMinutes = timeRemaining
                } else if let timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int {
                    snapshot.timeRemainingMinutes = timeToFull
                }

                break // Primary battery
            }
        }

        // 2. Query AppleSmartBattery IORegistry for Hardware Precision Telemetry
        let smartBatteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if smartBatteryService != 0 {
            defer { IOObjectRelease(smartBatteryService) }

            var props: Unmanaged<CFMutableDictionary>?
            let kr = IORegistryEntryCreateCFProperties(smartBatteryService, &props, kCFAllocatorDefault, 0)
            if kr == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] {
                // Exact hardware cycle count
                if let cycles = dict["CycleCount"] as? Int {
                    snapshot.cycleCount = cycles
                }

                // Voltage (mV)
                if let rawVolt = dict["Voltage"] as? Int {
                    snapshot.voltage = Double(rawVolt) / 1000.0
                }

                // Amperage (mA)
                if let rawAmp = (dict["Amperage"] ?? dict["InstantAmperage"]) as? Int {
                    snapshot.amperage = rawAmp
                }

                // Temperature
                if let rawTemp = dict["Temperature"] as? Int {
                    snapshot.temperature = Double(rawTemp) / 100.0
                }

                // Adapter Wattage
                if let adapterDetails = dict["AdapterDetails"] as? [String: Any],
                   let watts = adapterDetails["Watts"] as? Int {
                    snapshot.adapterWatts = watts
                }

                // System Load Wattage
                if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
                    if let sysLoad = telemetry["SystemLoad"] as? Int {
                        snapshot.systemLoadWatts = Double(sysLoad) / 1000.0
                    } else if let sysPowerIn = telemetry["SystemPowerIn"] as? Int {
                        snapshot.systemLoadWatts = Double(sysPowerIn) / 1000.0
                    }
                }
            }
        }

        // 3. SMC State and Dynamic Key Description
        snapshot.isChargeInhibited = SMCKit.shared.isChargingInhibited()
        snapshot.isPowerAdapterDisabled = SMCKit.shared.isPowerAdapterDisabled()

        if let key = SMCKit.shared.activeChargeKey {
            snapshot.activeSMCKey = "\(key.name) (Active)"
        } else {
            #if arch(arm64)
            snapshot.activeSMCKey = "Apple Silicon CH0B (Active)"
            #else
            snapshot.activeSMCKey = "Intel BCLM (Active)"
            #endif
        }

        // 4. Calculate Real-time Battery Wattage
        if snapshot.isChargeInhibited && snapshot.isACConnected {
            // In Sailing Mode (AC Bypass): 0.0 W to battery, laptop powered directly by charger
            snapshot.watts = 0.0
        } else {
            snapshot.watts = (snapshot.voltage * Double(abs(snapshot.amperage))) / 1000.0
        }

        if snapshot.systemLoadWatts == 0.0 {
            snapshot.systemLoadWatts = max(snapshot.watts, 8.5) // Graceful fallback
        }

        snapshot.timestamp = Date()
        return snapshot
    }

    private func handlePowerChange() {
        let snapshot = getCurrentSnapshot()
        onPowerStateChanged?(snapshot)
    }
}
