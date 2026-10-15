//
//  PowerUIClient.swift
//  BatteryToolkit - Native macOS 26 / 27 PowerUI Manual Charge Limit Controller
//

import Foundation
import os.log

public final class PowerUIClient: @unchecked Sendable {
    public static let shared = PowerUIClient()

    private var client: AnyObject?
    public private(set) var isSupported: Bool = false
    public private(set) var availableLimits: [Int] = [80, 85, 90, 95, 100]
    private let lock = NSLock()

    private init() {
        initClient()
    }

    private func initClient() {
        let path = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
        guard let _ = dlopen(path, RTLD_NOW) else {
            os_log("PowerUI.framework not found or cannot be opened", type: .info)
            return
        }

        guard let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else {
            os_log("PowerUISmartChargeClient class not found", type: .info)
            return
        }

        let obj = cls.init()
        let selInit = Selector(("initWithClientName:"))
        guard obj.responds(to: selInit),
              let instance = obj.perform(selInit, with: "BatteryToolkit")?.takeUnretainedValue() as AnyObject? else {
            os_log("Failed to initialize PowerUISmartChargeClient instance", type: .error)
            return
        }

        self.client = instance

        let selSupported = Selector(("isMCLSupported"))
        if instance.responds(to: selSupported) {
            typealias IsMCLSupportedFn = @convention(c) (AnyObject, Selector) -> Bool
            let fn: IsMCLSupportedFn = unsafeBitCast(class_getMethodImplementation(type(of: instance), selSupported), to: IsMCLSupportedFn.self)
            self.isSupported = fn(instance, selSupported)
        }

        let selAvail = Selector(("availableChargeLimitsWithError:"))
        if instance.responds(to: selAvail) {
            typealias AvailFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSArray?
            let fn: AvailFn = unsafeBitCast(class_getMethodImplementation(type(of: instance), selAvail), to: AvailFn.self)
            var err: NSError? = nil
            if let arr = fn(instance, selAvail, &err) as? [NSNumber] {
                self.availableLimits = arr.map { $0.intValue }.sorted()
            }
        }

        os_log("PowerUIClient initialized: supported=%{public}@, limits=%{public}@",
               type: .info, String(isSupported), availableLimits.description)
    }

    @discardableResult
    public func setLimit(_ limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let client = client, isSupported else { return false }
        let sel = Selector(("setMCLLimit:error:"))
        guard client.responds(to: sel) else { return false }

        typealias Fn = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let fn: Fn = unsafeBitCast(class_getMethodImplementation(type(of: client), sel), to: Fn.self)
        var err: NSError? = nil
        let success = fn(client, sel, UInt8(limit), &err)
        if !success {
            os_log("setMCLLimit to %{public}d failed: %{public}@", type: .error, limit, err?.localizedDescription ?? "unknown")
        }
        return success
    }

    @discardableResult
    public func enableMCL() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let client = client, isSupported else { return false }
        let sel = Selector(("enableMCL:"))
        guard client.responds(to: sel) else { return false }

        typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let fn: Fn = unsafeBitCast(class_getMethodImplementation(type(of: client), sel), to: Fn.self)
        var err: NSError? = nil
        let success = fn(client, sel, &err)
        if !success {
            os_log("enableMCL failed: %{public}@", type: .error, err?.localizedDescription ?? "unknown")
        }
        return success
    }

    @discardableResult
    public func disableMCL() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let client = client, isSupported else { return false }
        let sel = Selector(("disableMCL:"))
        guard client.responds(to: sel) else { return false }

        typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let fn: Fn = unsafeBitCast(class_getMethodImplementation(type(of: client), sel), to: Fn.self)
        var err: NSError? = nil
        let success = fn(client, sel, &err)
        if !success {
            os_log("disableMCL failed: %{public}@", type: .error, err?.localizedDescription ?? "unknown")
        }
        return success
    }

    @discardableResult
    public func temporarilyEnableCharging() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let client = client, isSupported else { return false }
        let sel = Selector(("temporarilyEnableCharging:"))
        guard client.responds(to: sel) else { return false }

        typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let fn: Fn = unsafeBitCast(class_getMethodImplementation(type(of: client), sel), to: Fn.self)
        var err: NSError? = nil
        let success = fn(client, sel, &err)
        return success
    }

    @discardableResult
    public func temporarilyOverrideTargetSoC(_ soc: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let client = client, isSupported else { return false }
        let sel = Selector(("temporarilyOverrideMCLTargetSoC:error:"))
        guard client.responds(to: sel) else { return false }

        typealias Fn = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let fn: Fn = unsafeBitCast(class_getMethodImplementation(type(of: client), sel), to: Fn.self)
        var err: NSError? = nil
        let success = fn(client, sel, UInt8(soc), &err)
        return success
    }

    public func getStatus() -> (limit: Int, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard let client = client, isSupported else { return (100, false) }
        var limitVal = 100
        var isEnabledVal = false

        let selGet = Selector(("getMCLLimitWithError:"))
        if client.responds(to: selGet) {
            typealias GetFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt8
            let fn: GetFn = unsafeBitCast(class_getMethodImplementation(type(of: client), selGet), to: GetFn.self)
            var err: NSError? = nil
            limitVal = Int(fn(client, selGet, &err))
        }

        let selEn = Selector(("isMCLCurrentlyEnabled:"))
        if client.responds(to: selEn) {
            typealias EnFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt64
            let fn: EnFn = unsafeBitCast(class_getMethodImplementation(type(of: client), selEn), to: EnFn.self)
            var err: NSError? = nil
            isEnabledVal = (fn(client, selEn, &err) != 0)
        }

        return (limitVal, isEnabledVal)
    }
}
