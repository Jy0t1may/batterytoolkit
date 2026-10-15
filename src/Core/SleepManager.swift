//
//  SleepManager.swift
//  BatteryToolkit - System Power Assertion & Sleep Management
//

import Foundation
import IOKit.pwr_mgt
import os.log

public final class SleepManager: @unchecked Sendable {
    public static let shared = SleepManager()

    private var assertionID: IOPMAssertionID = 0
    private var isSleepDisabled = false
    private let lock = NSLock()

    private init() {}

    public func disableSleep(reason: String = "BatteryToolkit: Charging to Target Threshold") {
        lock.lock()
        defer { lock.unlock() }

        guard !isSleepDisabled else { return }

        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        if success == kIOReturnSuccess {
            isSleepDisabled = true
            os_log("System sleep assertion created (ID: %{public}d)", type: .info, assertionID)
        } else {
            os_log("Failed to create sleep assertion: %{public}d", type: .error, success)
        }
    }

    public func restoreSleep() {
        lock.lock()
        defer { lock.unlock() }

        guard isSleepDisabled, assertionID != 0 else { return }

        let res = IOPMAssertionRelease(assertionID)
        if res == kIOReturnSuccess {
            os_log("System sleep assertion released (ID: %{public}d)", type: .info, assertionID)
            assertionID = 0
            isSleepDisabled = false
        }
    }
}
