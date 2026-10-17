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
            DispatchQueue.main.async {
                self?.isHelperInstalled = false
                self?.helperVersion = nil
            }
            completion?(false)
        }) as? BatteryHelperProtocol else {
            DispatchQueue.main.async {
                self.isHelperInstalled = false
                self.helperVersion = nil
            }
            completion?(false)
            return
        }

        helper.getVersion { [weak self] version in
            os_log("Connected to BatteryToolkit Helper v%{public}@ (target v%{public}@)",
                   type: .info, version, HelperConstants.helperVersion)
            DispatchQueue.main.async {
                self?.helperVersion = version
                // Enforce exact version equality like AlDente
                let matches = (version == HelperConstants.helperVersion)
                self?.isHelperInstalled = matches
                completion?(matches)
            }
        }
    }

    // MARK: - Root Sleep Assertions

    public func createSleepAssertion(reason: String, completion: @escaping (UInt32) -> Void) {
        let conn = getHelperConnection()
        guard let helper = conn.remoteObjectProxyWithErrorHandler({ error in
            os_log("Error requesting sleep assertion from helper: %{public}@", type: .error, error.localizedDescription)
            completion(0)
        }) as? BatteryHelperProtocol else {
            completion(0)
            return
        }

        helper.createAssertion(type: "PreventUserIdleSystemSleep", reason: reason) { id in
            completion(id)
        }
    }

    public func releaseSleepAssertion(id: UInt32, completion: ((Bool) -> Void)? = nil) {
        let conn = getHelperConnection()
        guard let helper = conn.remoteObjectProxyWithErrorHandler({ error in
            os_log("Error releasing sleep assertion from helper: %{public}@", type: .error, error.localizedDescription)
            completion?(false)
        }) as? BatteryHelperProtocol else {
            completion?(false)
            return
        }

        helper.releaseAssertion(id: id) { success in
            completion?(success)
        }
    }

    // MARK: - Hardware Charging Control

    public func setChargingInhibited(_ inhibited: Bool, limit: Int, completion: @escaping (Bool) -> Void) {
        let conn = getHelperConnection()
        guard let helper = conn.remoteObjectProxyWithErrorHandler({ error in
            os_log("Error sending setChargingInhibited to helper: %{public}@", type: .error, error.localizedDescription)
            completion(false)
        }) as? BatteryHelperProtocol else {
            completion(false)
            return
        }

        helper.setChargingInhibited(inhibited, limit: limit) { success in
            completion(success)
        }
    }

    // MARK: - Installation & Privilege Escalation

    /// Triggers user authorization to install and register the privileged helper daemon
    public func installHelperViaAppleScript(bundleHelperURL: URL, completion: @escaping (Bool, String?) -> Void) {
        let helperPath = bundleHelperURL.standardizedFileURL.path
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

        let tmpHelper = "/tmp/\(HelperConstants.helperID).bin"
        try? FileManager.default.removeItem(atPath: tmpHelper)
        try? FileManager.default.copyItem(atPath: helperPath, toPath: tmpHelper)

        let script = """
        do shell script "mkdir -p \(targetHelperDir) && cp '\(tmpHelper)' '\(targetHelperPath)' && chown root:wheel '\(targetHelperPath)' && chmod 755 '\(targetHelperPath)' && cp '\(tmpPlist)' '\(plistPath)' && chown root:wheel '\(plistPath)' && chmod 644 '\(plistPath)' && launchctl unload '\(plistPath)' 2>/dev/null; launchctl load -w '\(plistPath)'" with administrator privileges
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

            // Invalidate current connection so a fresh connection to the new daemon is created
            self.lock.lock()
            self.connection?.invalidate()
            self.connection = nil
            self.lock.unlock()

            // Verify installation
            Thread.sleep(forTimeInterval: 1.0)
            self.checkHelperStatus { success in
                completion(success, nil)
            }
        }
    }
}
