//
//  main_helper.swift
//  BatteryToolkit - Privileged Helper Daemon Entry Point
//

import Foundation
import os.log

final class ConnectionTracker {
    static let shared = ConnectionTracker()
    private var activeCount: Int = 0
    private let lock = NSLock()

    func connectionOpened() {
        lock.lock()
        activeCount += 1
        lock.unlock()
    }

    func connectionClosed() {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        let count = activeCount
        lock.unlock()

        if count == 0 {
            os_log("All clients disconnected from helper. Running watchdog reset...", type: .info)
            BatteryHelper.shared.resetDefaults { _ in }
        }
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        newConnection.exportedObject = BatteryHelper.shared

        ConnectionTracker.shared.connectionOpened()

        newConnection.invalidationHandler = {
            os_log("Helper XPC connection invalidated", type: .info)
            ConnectionTracker.shared.connectionClosed()
        }

        newConnection.interruptionHandler = {
            os_log("Helper XPC connection interrupted", type: .info)
        }

        newConnection.resume()
        return true
    }
}

@main
struct HelperDaemonMain {
    static func main() {
        os_log("Starting BatteryToolkit privileged helper daemon v%{public}@",
               type: .info, HelperConstants.helperVersion)

        let delegate = HelperDelegate()
        let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
        listener.delegate = delegate
        listener.resume()

        RunLoop.main.run()
    }
}
