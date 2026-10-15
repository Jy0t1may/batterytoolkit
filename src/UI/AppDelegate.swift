//
//  AppDelegate.swift
//  BatteryToolkit - Application Lifecycle Delegate
//

import AppKit
import Foundation

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
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
