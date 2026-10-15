//
//  main_helper.swift
//  BatteryToolkit - Privileged Helper Daemon Entry Point
//

import Foundation
import os.log

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        newConnection.exportedObject = BatteryHelper.shared
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
