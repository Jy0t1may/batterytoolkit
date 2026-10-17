//
//  SleepManager.swift
//  BatteryToolkit - System Power Assertion & Sleep Management
//

import Foundation
import IOKit.pwr_mgt
import os.log

public final class SleepManager: @unchecked Sendable {
    public static let shared = SleepManager()

    private var localAssertionID: IOPMAssertionID = 0
    private var helperAssertionID: UInt32 = 0
    private var isSleepDisabled = false
    private let lock = NSLock()

    private init() {}

    public func disableSleep(reason: String = "BatteryToolkit: Charging to Target Threshold") {
        lock.lock()
        defer { lock.unlock() }

        guard !isSleepDisabled else { return }

        // 1. Delegate to root Privileged Helper daemon if available (AlDente Model)
        HelperManager.shared.createSleepAssertion(reason: reason) { [weak self] id in
            self?.lock.lock()
            if id != 0 {
                self?.helperAssertionID = id
                os_log("Root sleep assertion active in privileged helper (ID: %{public}u)", type: .info, id)
            }
            self?.lock.unlock()
        }

        // 2. Also hold local assertion as belt-and-suspenders
        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &localAssertionID
        )

        if success == kIOReturnSuccess {
            os_log("Local user sleep assertion created (ID: %{public}u)", type: .info, localAssertionID)
        }

        isSleepDisabled = true
    }

    public func restoreSleep() {
        lock.lock()
        defer { lock.unlock() }

        guard isSleepDisabled else { return }

        // 1. Release root helper assertion
        if helperAssertionID != 0 {
            let hid = helperAssertionID
            helperAssertionID = 0
            HelperManager.shared.releaseSleepAssertion(id: hid) { _ in }
        }

        // 2. Release local assertion
        if localAssertionID != 0 {
            _ = IOPMAssertionRelease(localAssertionID)
            localAssertionID = 0
        }

        isSleepDisabled = false
        os_log("Sleep assertions restored to default", type: .info)
    }
}
