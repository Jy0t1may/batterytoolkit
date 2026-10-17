//
//  AppDelegate.swift
//  BatteryToolkit - Application Lifecycle Delegate
//

import AppKit
import Foundation

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var instance: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.instance = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as menu bar accessory app
        NSApp.setActivationPolicy(.accessory)

        // Initialize Sailing Manager
        SailingManager.shared.start()

        // Setup Menu Bar Extra Item
        StatusItemController.shared.setup()

        // Check Privileged Helper status on startup (AlDente Model)
        HelperManager.shared.checkHelperStatus { isUpToDate in
            if !isUpToDate {
                NSLog("BatteryToolkit: Privileged helper not installed or outdated. Prompting user for administrator privileges...")
                let bundleHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/me.batterytoolkit.helper")
                HelperManager.shared.installHelperViaAppleScript(bundleHelperURL: bundleHelper) { success, error in
                    if success {
                        NSLog("BatteryToolkit: Privileged helper v%@ installed and verified successfully.", HelperConstants.helperVersion)
                        DispatchQueue.main.async {
                            DashboardViewModel.shared.refresh()
                        }
                    } else {
                        NSLog("BatteryToolkit: Privileged helper installation deferred/failed: %@", error ?? "unknown")
                    }
                }
            } else {
                NSLog("BatteryToolkit: Privileged helper v%@ is active and running.", HelperConstants.helperVersion)
            }
        }

        NSLog("BatteryToolkit started successfully with Sailing Mode active.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore hardware to safe defaults on quit
        SleepManager.shared.restoreSleep()
        SMCKit.shared.setChargingInhibited(false)
        SMCKit.shared.setPowerAdapterDisabled(false)
        SMCKit.shared.setMagSafeLED(state: .system)

        NSLog("BatteryToolkit terminated gracefully. Restored normal charging.")
    }
}
