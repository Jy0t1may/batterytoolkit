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
    private var pollTimer: DispatchSourceTimer?
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

        // High-frequency 500ms (2Hz) timer for responsive real-time wattage & system load
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.handlePowerChange()
        }
        timer.resume()
        self.pollTimer = timer

        isListening = true
        handlePowerChange()
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        guard isListening else { return }
        notify_cancel(powerToken)
        notify_cancel(percentToken)
        pollTimer?.cancel()
        pollTimer = nil
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
                // Physical Adapter Connection Check
                var ioregConnected = false
                if let ext = dict["ExternalConnected"] as? Bool {
                    ioregConnected = ext
                } else if let extInt = dict["ExternalConnected"] as? Int {
                    ioregConnected = (extInt != 0)
                }

                if !ioregConnected {
                    if let rawExt = dict["AppleRawExternalConnected"] as? Bool {
                        ioregConnected = rawExt
                    } else if let rawExtInt = dict["AppleRawExternalConnected"] as? Int {
                        ioregConnected = (rawExtInt != 0)
                    }
                }

                if ioregConnected {
                    if let adapterDetails = dict["AdapterDetails"] as? [String: Any],
                       let watts = adapterDetails["Watts"] as? Int {
                        snapshot.adapterWatts = watts
                    }
                } else {
                    snapshot.adapterWatts = 0
                }

                let isPluggedIn = snapshot.isACConnected || ioregConnected
                snapshot.isACConnected = isPluggedIn
                snapshot.isPhysicalAdapterAttached = isPluggedIn

                if !isPluggedIn {
                    snapshot.isCharging = false
                    snapshot.isChargeInhibited = false
                    snapshot.adapterWatts = 0
                } else {
                    // Hardware NotCharging Reason
                    if let notChargingReason = dict["NotChargingReason"] as? Int, notChargingReason != 0 {
                        snapshot.isChargeInhibited = true
                    }

                    // Hardware IsCharging Flag
                    if let hwCharging = dict["IsCharging"] as? Bool {
                        snapshot.isCharging = hwCharging
                    } else if let hwChargingInt = dict["IsCharging"] as? Int {
                        snapshot.isCharging = (hwChargingInt != 0)
                    }
                }

                // Exact hardware cycle count
                if let cycles = dict["CycleCount"] as? Int {
                    snapshot.cycleCount = cycles
                }

                // Voltage (mV)
                if let rawVolt = dict["Voltage"] as? Int {
                    snapshot.voltage = Double(rawVolt) / 1000.0
                }

                // Amperage (mA) - Handle 64-bit signed two's complement conversion
                if let rawAmp = (dict["Amperage"] ?? dict["InstantAmperage"]) as? Int {
                    if rawAmp > 0x7FFFFFFF {
                        snapshot.amperage = Int(Int32(truncatingIfNeeded: rawAmp))
                    } else if rawAmp > 0x7FFF && rawAmp < 0x10000 {
                        snapshot.amperage = Int(Int16(truncatingIfNeeded: rawAmp))
                    } else {
                        snapshot.amperage = rawAmp
                    }
                }

                // Temperature
                if let rawTemp = dict["Temperature"] as? Int {
                    snapshot.temperature = Double(rawTemp) / 100.0
                }

                // Adapter Wattage
                if snapshot.adapterWatts == 0,
                   let adapterDetails = dict["AdapterDetails"] as? [String: Any],
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

        // 3. Hardware State & PMU Description
        snapshot.isPowerAdapterDisabled = SMCKit.shared.isPowerAdapterDisabled()
        snapshot.activeSMCKey = "Apple Silicon PMU Bypass"

        let smcInhibit = SMCKit.shared.isChargingInhibited()
        if smcInhibit {
            snapshot.isChargeInhibited = true
            snapshot.isCharging = false
        }

        // 4. Calculate Real-time Hardware Battery Wattage
        let liveAmperage = snapshot.amperage
        let liveVoltage = snapshot.voltage

        if abs(liveAmperage) <= 60 {
            // Under 60 mA is negligible idle current / true AC bypass
            snapshot.watts = 0.0
        } else {
            snapshot.watts = (liveVoltage * Double(abs(liveAmperage))) / 1000.0
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
