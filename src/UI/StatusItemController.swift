//
//  StatusItemController.swift
//  BatteryToolkit - Menu Bar Extra & Popover Manager
//

import AppKit
import SwiftUI
import Foundation

public final class StatusItemController: NSObject, NSPopoverDelegate, @unchecked Sendable {
    public static let shared = StatusItemController()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var contextMenu: NSMenu!
    private let viewModel = DashboardViewModel.shared
    private var observerUUID: UUID?

    public func setup() {
        // Create NSStatusItem in the system menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleButtonClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Initialize SwiftUI Popover
        let hostingController = NSHostingController(rootView: DashboardView(viewModel: viewModel))
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hostingController

        // Build Right-Click Context Menu
        buildContextMenu()

        // Observe Status Updates using Multicast Observer
        self.observerUUID = SailingManager.shared.addObserver { [weak self] status, desc, snapshot in
            DispatchQueue.main.async {
                self?.updateStatusItem(status: status, snapshot: snapshot)
            }
        }

        let initialSnapshot = PowerMonitor.shared.getCurrentSnapshot()
        updateStatusItem(status: SailingManager.shared.currentStatus, snapshot: initialSnapshot)
    }

    deinit {
        if let id = observerUUID {
            SailingManager.shared.removeObserver(id)
        }
    }

    // MARK: - Memory Optimization on Popover Close (Issue 5)
    public func popoverDidClose(_ notification: Notification) {
        // Clean and compact heap memory when the popover is dismissed
        malloc_zone_pressure_relief(nil, 0)
    }

    private func buildContextMenu() {
        contextMenu = NSMenu(title: "BatteryToolkit")

        let titleItem = NSMenuItem(title: "BatteryToolkit (Sailing Mode)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        contextMenu.addItem(titleItem)
        contextMenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Dashboard...", action: #selector(openDashboard), keyEquivalent: "o")
        openItem.target = self
        contextMenu.addItem(openItem)

        let toggleSailingItem = NSMenuItem(title: "Toggle Sailing Mode", action: #selector(toggleSailing), keyEquivalent: "s")
        toggleSailingItem.target = self
        contextMenu.addItem(toggleSailingItem)

        let chargeFullItem = NSMenuItem(title: "Charge to 100% Once", action: #selector(chargeTo100), keyEquivalent: "f")
        chargeFullItem.target = self
        contextMenu.addItem(chargeFullItem)

        let inhibitItem = NSMenuItem(title: "Inhibit Charging (AC Bypass)", action: #selector(inhibitCharging), keyEquivalent: "i")
        inhibitItem.target = self
        contextMenu.addItem(inhibitItem)

        let resumeItem = NSMenuItem(title: "Resume Sailing Schedule", action: #selector(resumeSchedule), keyEquivalent: "r")
        resumeItem.target = self
        contextMenu.addItem(resumeItem)

        contextMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit BatteryToolkit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)
    }

    public func updateStatusItem(status: ChargingStatus, snapshot: BatterySnapshot) {
        guard let button = statusItem?.button else { return }

        let percent = snapshot.percentage
        var iconStr = "🔋"
        switch status {
        case .sailing:
            iconStr = "⛵️"
        case .charging:
            iconStr = "⚡️"
        case .discharging:
            iconStr = "🔋"
        case .charged:
            iconStr = "🔌"
        case .paused:
            iconStr = "🛑"
        case .unsupported:
            iconStr = "⚠️"
        }

        button.title = "\(percent)% \(iconStr)"
        button.toolTip = "BatteryToolkit: \(SailingManager.shared.statusDescription)"
    }

    @objc private func handleButtonClick(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // Right-click: display context menu
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        // Left-click: toggle popover
        if popover.isShown {
            popover.performClose(sender)
        } else {
            viewModel.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openDashboard() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            viewModel.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func toggleSailing() {
        let current = SailingManager.shared.settings.sailingEnabled
        SailingManager.shared.setSailingEnabled(!current)
        viewModel.refresh()
    }

    @objc private func chargeTo100() {
        SailingManager.shared.chargeToFullOnce()
        viewModel.refresh()
    }

    @objc private func inhibitCharging() {
        SailingManager.shared.stopChargingNow()
        viewModel.refresh()
    }

    @objc private func resumeSchedule() {
        SailingManager.shared.resumeNormalSchedule()
        viewModel.refresh()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
