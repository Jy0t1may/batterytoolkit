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
    private var lastHardwareInhibited: Bool? = nil

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
        self.lastHardwareInhibited = nil
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
        self.lastHardwareInhibited = nil
        stateLock.unlock()

        SMCKit.shared.setChargingInhibited(true)
        SleepManager.shared.restoreSleep()

        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        evaluatePowerState(snapshot: snapshot)
    }

    public func resumeNormalSchedule() {
        stateLock.lock()
        self.currentMode = .sailing
        self.lastHardwareInhibited = nil
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

        let isPluggedIn = snapshot.isACConnected || snapshot.isPhysicalAdapterAttached

        if !isPluggedIn {
            // Running on Battery (unplugged)
            currentStatus = .discharging
            isCurrentlySailing = false
            statusDescription = "Running on Battery (\(percent)%)"
            SleepManager.shared.restoreSleep()
            notifyObservers(status: currentStatus, desc: statusDescription, snapshot: snapshot)
            return
        }

        // On AC Charger
        var desiredInhibit: Bool = false
        var newStatus: ChargingStatus = .charging
        var newDescription: String = ""
        var preventSleep: Bool = false

        switch currentMode {
        case .manualHold:
            desiredInhibit = true
            newStatus = .paused
            newDescription = "Charging Manually Inactive (Holding at \(percent)%)"

        case .fullChargeOnce:
            if percent >= 100 {
                currentMode = .sailing
                isCurrentlySailing = true
                desiredInhibit = true
                newStatus = .charged
                newDescription = "Full Charge Complete (100%). Returning to Sailing Mode."
            } else {
                desiredInhibit = false
                preventSleep = true
                newStatus = .charging
                newDescription = "Charging to 100% (\(percent)%)"
            }

        case .directLimit:
            if percent >= targetLimit {
                desiredInhibit = true
                newStatus = .charged
                newDescription = "Powered by Adapter (Holding at limit \(targetLimit)%)"
            } else {
                desiredInhibit = false
                preventSleep = true
                newStatus = .charging
                newDescription = "Charging to \(targetLimit)% (\(percent)%)"
            }

        case .sailing:
            if percent >= targetLimit {
                isCurrentlySailing = true
                desiredInhibit = true
                newStatus = .sailing
                newDescription = "Powered by Power Adapter (Sailing: \(percent)% ➔ Resumes at \(resumeThreshold)%)"
            } else if isCurrentlySailing {
                if percent <= resumeThreshold {
                    isCurrentlySailing = false
                    desiredInhibit = false
                    preventSleep = true
                    newStatus = .charging
                    newDescription = "Charging to \(targetLimit)% (Resumed from \(percent)%)"
                } else {
                    desiredInhibit = true
                    newStatus = .sailing
                    newDescription = "Powered by Power Adapter (Sailing: \(percent)% ➔ Resumes at \(resumeThreshold)%)"
                }
            } else {
                if percent < targetLimit {
                    desiredInhibit = false
                    preventSleep = true
                    newStatus = .charging
                    newDescription = "Charging to \(targetLimit)% (\(percent)%)"
                } else {
                    isCurrentlySailing = true
                    desiredInhibit = true
                    newStatus = .sailing
                    newDescription = "Powered by Power Adapter (Sailing Active: \(percent)%)"
                }
            }
        }

        // Apply hardware inhibition ONLY if changed!
        if lastHardwareInhibited != desiredInhibit {
            lastHardwareInhibited = desiredInhibit
            SMCKit.shared.setChargingInhibited(desiredInhibit)
            if desiredInhibit {
                SleepManager.shared.restoreSleep()
                if settings.magSafeSyncEnabled {
                    SMCKit.shared.setMagSafeLED(state: .green)
                }
            } else {
                if preventSleep {
                    SleepManager.shared.disableSleep(reason: "BatteryToolkit: Charging")
                }
                if settings.magSafeSyncEnabled {
                    SMCKit.shared.setMagSafeLED(state: .orange)
                }
            }
        }

        currentStatus = newStatus
        statusDescription = newDescription

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
