//
//  HelperManager.swift
//  BatteryToolkit - Privileged Helper Installer & Manager
//

import Foundation
import ServiceManagement
import os.log

public final class HelperManager: @unchecked Sendable {
    public static let shared = HelperManager()

    private var connection: NSXPCConnection?
    private let lock = NSLock()

    @Published public private(set) var isHelperInstalled: Bool = false
    @Published public private(set) var helperVersion: String? = nil

    private init() {
        checkHelperStatus()
    }

    public func getHelperConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }

        if let existing = connection {
            return existing
        }

        let conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        conn.interruptionHandler = { [weak self] in
            os_log("Helper XPC connection interrupted", type: .info)
            self?.lock.lock()
            self?.connection = nil
            self?.lock.unlock()
        }
        conn.invalidationHandler = { [weak self] in
            os_log("Helper XPC connection invalidated", type: .info)
            self?.lock.lock()
            self?.connection = nil
            self?.lock.unlock()
        }
        conn.resume()
        self.connection = conn
        return conn
    }

    public func checkHelperStatus(completion: ((Bool) -> Void)? = nil) {
        let conn = getHelperConnection()
        guard let helper = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
            os_log("Helper connection error: %{public}@", type: .debug, error.localizedDescription)
            self?.isHelperInstalled = false
            completion?(false)
        }) as? BatteryHelperProtocol else {
            self.isHelperInstalled = false
            completion?(false)
            return
        }

        helper.getVersion { [weak self] version in
            os_log("Connected to BatteryToolkit Helper v%{public}@", type: .info, version)
            self?.helperVersion = version
            self?.isHelperInstalled = true
            completion?(true)
        }
    }

    /// Triggers user authorization to install and register the privileged helper daemon
    public func installHelperViaAppleScript(bundleHelperURL: URL, completion: @escaping (Bool, String?) -> Void) {
        let helperPath = bundleHelperURL.path
        let targetHelperDir = "/Library/PrivilegedHelperTools"
        let targetHelperPath = "\(targetHelperDir)/\(HelperConstants.helperID)"
        let plistPath = "/Library/LaunchDaemons/\(HelperConstants.helperID).plist"

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperConstants.helperID)</string>
            <key>Program</key>
            <string>\(targetHelperPath)</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>MachServices</key>
            <dict>
                <key>\(HelperConstants.machServiceName)</key>
                <true/>
            </dict>
        </dict>
        </plist>
        """

        let tmpPlist = "/tmp/\(HelperConstants.helperID).plist"
        try? plistContent.write(toFile: tmpPlist, atomically: true, encoding: .utf8)

        let script = """
        do shell script "mkdir -p \(targetHelperDir) && cp '\(helperPath)' '\(targetHelperPath)' && chown root:wheel '\(targetHelperPath)' && chmod 755 '\(targetHelperPath)' && cp '\(tmpPlist)' '\(plistPath)' && chown root:wheel '\(plistPath)' && chmod 644 '\(plistPath)' && launchctl unload '\(plistPath)' 2>/dev/null; launchctl load -w '\(plistPath)'" with administrator privileges
        """

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                _ = appleScript.executeAndReturnError(&error)
                if let error = error {
                    let errMsg = error[NSAppleScript.errorMessage] as? String ?? "Authorization failed"
                    os_log("Helper installation failed: %{public}@", type: .error, errMsg)
                    DispatchQueue.main.async { completion(false, errMsg) }
                    return
                }
            }

            // Verify installation
            Thread.sleep(forTimeInterval: 1.0)
            DispatchQueue.main.async {
                self.checkHelperStatus { success in
                    completion(success, nil)
                }
            }
        }
    }
}
