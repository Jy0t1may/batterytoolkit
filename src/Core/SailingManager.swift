//
//  SailingManager.swift
//  BatteryToolkit - Sailing Mode Engine & Multicast State Machine
//

import Foundation
import os.log

public final class SailingManager: @unchecked Sendable {
    public static let shared = SailingManager()

    public private(set) var settings: SailingSettings
    public private(set) var currentMode: ChargingMode = .sailing
    public private(set) var isCurrentlySailing: Bool = false
    public private(set) var currentStatus: ChargingStatus = .discharging
    public private(set) var statusDescription: String = "Initializing..."

    public typealias StatusListener = @Sendable (ChargingStatus, String, BatterySnapshot) -> Void
    private var observers: [UUID: StatusListener] = [:]
    private let observerLock = NSLock()

    private let userDefaultsKey = "com.batterytoolkit.sailing.settings"
    private let stateLock = NSLock()

    public static let stateChangedNotification = NSNotification.Name("BatteryToolkitStateChanged")

    private init() {
        self.settings = SailingManager.loadSettings()
    }

    public func start() {
        PowerMonitor.shared.onPowerStateChanged = { [weak self] snapshot in
            self?.evaluatePowerState(snapshot: snapshot)
        }
        PowerMonitor.shared.startMonitoring()

        let initialSnapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: initialSnapshot)
    }

    // MARK: - Observer Registration (Multicast)
    @discardableResult
    public func addObserver(_ listener: @escaping StatusListener) -> UUID {
        let id = UUID()
        observerLock.lock()
        observers[id] = listener
        observerLock.unlock()

        // Send current snapshot immediately
        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        listener(currentStatus, statusDescription, snapshot)
        return id
    }

    public func removeObserver(_ id: UUID) {
        observerLock.lock()
        observers.removeValue(forKey: id)
        observerLock.unlock()
    }

    private func notifyObservers(status: ChargingStatus, desc: String, snapshot: BatterySnapshot) {
        observerLock.lock()
        let listeners = Array(observers.values)
        observerLock.unlock()

        DispatchQueue.main.async {
            for listener in listeners {
                listener(status, desc, snapshot)
            }
            NotificationCenter.default.post(
                name: SailingManager.stateChangedNotification,
                object: nil
            )
        }
    }

    public func updateSettings(_ newSettings: SailingSettings) {
        stateLock.lock()
        self.settings = newSettings
        SailingManager.saveSettings(newSettings)
        stateLock.unlock()

        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: snapshot)
    }

    public func setTargetLimit(_ limit: Int) {
        stateLock.lock()
        self.settings.targetLimit = min(100, max(50, limit))
        SailingManager.saveSettings(self.settings)
        stateLock.unlock()

        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: snapshot)
    }

    public func setSailingDrop(_ drop: Int) {
        stateLock.lock()
        self.settings.sailingDrop = min(30, max(2, drop))
        SailingManager.saveSettings(self.settings)
        stateLock.unlock()

        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: snapshot)
    }

    public func setSailingEnabled(_ enabled: Bool) {
        stateLock.lock()
        self.settings.sailingEnabled = enabled
        if !enabled {
            self.isCurrentlySailing = false
        }
        SailingManager.saveSettings(self.settings)
        stateLock.unlock()

        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: snapshot)
    }

    public func chargeToFullOnce() {
        stateLock.lock()
        self.currentMode = .fullChargeOnce
        self.isCurrentlySailing = false
        stateLock.unlock()

        SMCKit.shared.setChargingInhibited(false)
        SleepManager.shared.disableSleep(reason: "BatteryToolkit: Charging to 100%")

        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: snapshot)
    }

    public func stopChargingNow() {
        stateLock.lock()
        self.currentMode = .manualHold
        self.isCurrentlySailing = false
        stateLock.unlock()

        SMCKit.shared.setChargingInhibited(true)
        SleepManager.shared.restoreSleep()

        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: snapshot)
    }

    public func resumeNormalSchedule() {
        stateLock.lock()
        self.currentMode = .sailing
        stateLock.unlock()

        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: snapshot)
    }

    // MARK: - Core State Machine
    public func evaluatePowerState(snapshot: BatterySnapshot) {
        stateLock.lock()
        defer { stateLock.unlock() }

        let percent = snapshot.percentage
        let targetLimit = settings.targetLimit
        let resumeThreshold = settings.resumeThreshold

        if !snapshot.isACConnected {
            // Running on Battery (unplugged)
            currentStatus = .discharging
            isCurrentlySailing = false
            statusDescription = "Running on Battery (\(percent)%)"
            SleepManager.shared.restoreSleep()
            notifyObservers(status: currentStatus, desc: statusDescription, snapshot: snapshot)
            return
        }

        // On AC Charger
        switch currentMode {
        case .manualHold:
            SMCKit.shared.setChargingInhibited(true)
            currentStatus = .paused
            statusDescription = "Charging Manually Inactive (Holding at \(percent)%)"
            if settings.magSafeSyncEnabled {
                SMCKit.shared.setMagSafeLED(state: .orange)
            }

        case .fullChargeOnce:
            if percent >= 100 {
                // Reached 100%, return to sailing mode
                currentMode = .sailing
                isCurrentlySailing = true
                SMCKit.shared.setChargingInhibited(true)
                SleepManager.shared.restoreSleep()
                currentStatus = .charged
                statusDescription = "Full Charge Complete (100%). Returning to Sailing Mode."
                if settings.magSafeSyncEnabled {
                    SMCKit.shared.setMagSafeLED(state: .green)
                }
            } else {
                SMCKit.shared.setChargingInhibited(false)
                SleepManager.shared.disableSleep(reason: "BatteryToolkit: Charging to 100%")
                currentStatus = .charging
                statusDescription = "Charging to 100% (\(percent)%)"
                if settings.magSafeSyncEnabled {
                    SMCKit.shared.setMagSafeLED(state: .orange)
                }
            }

        case .directLimit:
            if percent >= targetLimit {
                SMCKit.shared.setChargingInhibited(true)
                SleepManager.shared.restoreSleep()
                currentStatus = .charged
                statusDescription = "Powered by Adapter (Holding at limit \(targetLimit)%)"
                if settings.magSafeSyncEnabled {
                    SMCKit.shared.setMagSafeLED(state: .green)
                }
            } else {
                SMCKit.shared.setChargingInhibited(false)
                SleepManager.shared.disableSleep(reason: "BatteryToolkit: Charging to Limit")
                currentStatus = .charging
                statusDescription = "Charging to \(targetLimit)% (\(percent)%)"
                if settings.magSafeSyncEnabled {
                    SMCKit.shared.setMagSafeLED(state: .orange)
                }
            }

        case .sailing:
            if percent >= targetLimit {
                // Upper limit reached -> Inhibit charging, enter Sailing Mode!
                isCurrentlySailing = true
                SMCKit.shared.setChargingInhibited(true)
                SleepManager.shared.restoreSleep()
                currentStatus = .sailing
                statusDescription = "Powered by Power Adapter (Sailing: \(percent)% ➔ Resumes at \(resumeThreshold)%)"
                if settings.magSafeSyncEnabled {
                    SMCKit.shared.setMagSafeLED(state: .green)
                }
            } else if isCurrentlySailing {
                // Currently Sailing
                if percent <= resumeThreshold {
                    // Dropped to or below lower resume threshold -> Re-engage charging!
                    isCurrentlySailing = false
                    SMCKit.shared.setChargingInhibited(false)
                    SleepManager.shared.disableSleep(reason: "BatteryToolkit: Sailing Resumed Charging")
                    currentStatus = .charging
                    statusDescription = "Charging to \(targetLimit)% (Resumed from \(percent)%)"
                    if settings.magSafeSyncEnabled {
                        SMCKit.shared.setMagSafeLED(state: .orange)
                    }
                } else {
                    // Still Sailing within the buffer zone:
                    // Mac runs on AC power adapter; battery charge slowly loses power only via natural self-discharge!
                    SMCKit.shared.setChargingInhibited(true)
                    SleepManager.shared.restoreSleep()
                    currentStatus = .sailing
                    statusDescription = "Powered by Power Adapter (Sailing: \(percent)% ➔ Resumes at \(resumeThreshold)%)"
                    if settings.magSafeSyncEnabled {
                        SMCKit.shared.setMagSafeLED(state: .green)
                    }
                }
            } else {
                // Not sailing, below targetLimit -> Charge up to target limit
                if percent < targetLimit {
                    SMCKit.shared.setChargingInhibited(false)
                    SleepManager.shared.disableSleep(reason: "BatteryToolkit: Charging to Target Limit")
                    currentStatus = .charging
                    statusDescription = "Charging to \(targetLimit)% (\(percent)%)"
                    if settings.magSafeSyncEnabled {
                        SMCKit.shared.setMagSafeLED(state: .orange)
                    }
                } else {
                    isCurrentlySailing = true
                    SMCKit.shared.setChargingInhibited(true)
                    SleepManager.shared.restoreSleep()
                    currentStatus = .sailing
                    statusDescription = "Powered by Power Adapter (Sailing Active: \(percent)%)"
                    if settings.magSafeSyncEnabled {
                        SMCKit.shared.setMagSafeLED(state: .green)
                    }
                }
            }
        }

        os_log("SailingManager: status=%{public}@, sailing=%{public}@, desc=%{public}@",
               type: .info, currentStatus.rawValue, String(isCurrentlySailing), statusDescription)
        notifyObservers(status: currentStatus, desc: statusDescription, snapshot: snapshot)
    }

    // MARK: - Persistence
    private static func loadSettings() -> SailingSettings {
        guard let data = UserDefaults.standard.data(forKey: "com.batterytoolkit.sailing.settings"),
              let settings = try? JSONDecoder().decode(SailingSettings.self, from: data) else {
            return SailingSettings.default
        }
        return settings
    }

    private static func saveSettings(_ settings: SailingSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "com.batterytoolkit.sailing.settings")
        }
    }
}
