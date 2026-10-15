//
//  main_cli.swift
//  BatteryToolkit - Command Line Interface & Verification Suite
//

import Foundation

@main
struct BatteryToolkitCLI {
    static func printBanner() {
        print("""
        ========================================================
           BatteryToolkit - Sailing Mode & Battery Manager
           macOS Sequoia & macOS 27 Compatibility Edition
        ========================================================
        """)
    }

    static func printHelp() {
        print("""
        Usage: batterytoolkit-cli <command> [arguments]

        Commands:
          status                    Show current battery, power, and sailing status
          set-limit <50-100>        Set target charge limit (e.g., 85)
          set-drop <2-30>           Set sailing drop range (e.g., 10 -> resumes at limit-10)
          sailing-on                Enable Sailing Mode
          sailing-off               Disable Sailing Mode
          charge-full               Charge battery to 100% once
          stop                      Inhibit charging immediately (run on AC power)
          resume                    Resume normal Sailing Mode schedule
          smc-dump                  Inspect hardware SMC keys and attributes
          test-sailing              Run automated verification test of Sailing Mode hysteresis
          help                      Show this help message
        """)
    }

    static func main() {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            printBanner()
            printHelp()
            exit(0)
        }

        let command = args[1].lowercased()
        let smc = SMCKit.shared
        let sailing = SailingManager.shared
        let power = PowerMonitor.shared

        switch command {
        case "status":
            printBanner()
            let snapshot = power.getCurrentSnapshot()
            sailing.evaluatePowerState(snapshot: snapshot)

            let settings = sailing.settings
            let isSailing = sailing.isCurrentlySailing

            print("--- Power & Battery State ---")
            print("  Battery Level       : \(snapshot.percentage)%")
            print("  Power Source        : \(snapshot.isACConnected ? "AC Adapter (Connected)" : "Battery Power")")
            print("  Battery Charging    : \(snapshot.isCharging ? "YES (Drawing Current)" : "NO (Charging Inactive)")")
            print("  Charge Inhibited    : \(snapshot.isChargeInhibited ? "YES (Mac powered by AC charger)" : "NO")")
            print("  Power Adapter Cut   : \(snapshot.isPowerAdapterDisabled ? "YES" : "NO")")
            print("")
            print("--- Sailing Mode Settings ---")
            print("  Sailing Mode Enabled: \(settings.sailingEnabled ? "YES" : "NO")")
            print("  Target Charge Limit : \(settings.targetLimit)%")
            print("  Sailing Drop Range  : \(settings.sailingDrop)%")
            print("  Resume Threshold    : \(settings.resumeThreshold)%")
            print("  Currently Sailing   : \(isSailing ? "YES (AC Powered - Natural Loss Buffer)" : "NO")")
            print("  Status Description  : \(sailing.statusDescription)")
            print("")
            print("--- Real-Time Wattage & Power Flow ---")
            if snapshot.isChargeInhibited && snapshot.isACConnected {
                print("  Battery Power Flow  : 0.0 W (Idle - Mac Powered by AC Adapter)")
            } else if snapshot.isCharging {
                print("  Battery Power Flow  : +\(String(format: "%.2f W", snapshot.watts)) (Charging Inflow)")
            } else {
                print("  Battery Power Flow  : -\(String(format: "%.2f W", snapshot.watts)) (Discharge Rate)")
            }
            print("  System Load Draw    : \(String(format: "%.1f W", snapshot.systemLoadWatts))")
            if snapshot.adapterWatts > 0 {
                print("  AC Adapter Rating   : \(snapshot.adapterWatts) W")
            }
            print("")
            print("--- Hardware Telemetry ---")
            print("  Hardware Model      : \(snapshot.architecture)")
            print("  SMC Control Mode    : \(snapshot.activeSMCKey)")
            print("  Cycle Count         : \(snapshot.cycleCount)")
            print("  Voltage             : \(String(format: "%.2f V", snapshot.voltage))")
            print("  Amperage            : \(snapshot.amperage) mA")
            print("  Temperature         : \(String(format: "%.1f °C", snapshot.temperature))")
            print("========================================================")

        case "set-limit":
            guard args.count > 2, let limit = Int(args[2]), limit >= 50, limit <= 100 else {
                print("Error: Limit must be an integer between 50 and 100.")
                exit(1)
            }
            sailing.setTargetLimit(limit)
            print("✓ Target charge limit set to \(limit)%. Resume threshold is now \(sailing.settings.resumeThreshold)%.")

        case "set-drop":
            guard args.count > 2, let drop = Int(args[2]), drop >= 2, drop <= 30 else {
                print("Error: Drop must be an integer between 2 and 30.")
                exit(1)
            }
            sailing.setSailingDrop(drop)
            print("✓ Sailing drop range set to \(drop)%. Charging will resume at \(sailing.settings.resumeThreshold)%.")

        case "sailing-on":
            sailing.setSailingEnabled(true)
            print("✓ Sailing Mode ENABLED (Limit: \(sailing.settings.targetLimit)%, Resumes: \(sailing.settings.resumeThreshold)%).")

        case "sailing-off":
            sailing.setSailingEnabled(false)
            print("✓ Sailing Mode DISABLED (Strict limit mode active).")

        case "charge-full":
            sailing.chargeToFullOnce()
            print("✓ Initiated one-time full charge to 100%. System will resume Sailing Mode once complete.")

        case "stop":
            sailing.stopChargingNow()
            print("✓ Charging inhibited. The Mac is now running directly on AC adapter power.")

        case "resume":
            sailing.resumeNormalSchedule()
            print("✓ Resumed normal Sailing Mode schedule.")

        case "smc-dump":
            printBanner()
            print("Inspecting AppleSMC Keys on this Mac:")
            let keysToInspect = [
                ("CH0B", SMCKnownKeys.CH0B.code),
                ("CH0C", SMCKnownKeys.CH0C.code),
                ("CH0J", SMCKnownKeys.CH0J.code),
                ("CHTE", SMCKnownKeys.CHTE.code),
                ("CHIE", SMCKnownKeys.CHIE.code),
                ("BCLM", SMCKnownKeys.BCLM.code),
                ("BRSC", SMCKnownKeys.BRSC),
                ("B0CT", SMCKnownKeys.B0CT),
                ("AC-W", SMCKnownKeys.AC_W)
            ]
            for (name, code) in keysToInspect {
                if let info = smc.getKeyInfo(code) {
                    let valBytes = smc.readBytes(code, count: min(8, info.size))?.map { String(format: "%02x", $0) }.joined(separator: " ") ?? "N/A"
                    print("  [\(name)] FOUND - Size: \(info.size) bytes, Type: 0x\(String(info.type, radix: 16)), Attr: 0x\(String(info.attr, radix: 16)), Val: [ \(valBytes) ]")
                } else {
                    print("  [\(name)] NOT FOUND or restricted")
                }
            }
            print("Active Charge Inhibit Key : \(smc.activeChargeKey?.name ?? "Apple Silicon CH0B (Active)")")
            print("Active Adapter Key        : \(smc.activeAdapterKey?.name ?? "Simulated / Fallback")")
            print("MagSafe 3 LED Supported   : \(smc.magSafeSupported ? "YES" : "NO")")

        case "test-sailing":
            printBanner()
            print("Running Automated Sailing Mode Verification Suite...")
            print("Target Limit: 85% | Sailing Drop: 10% | Resume Threshold: 75%")
            print("")

            sailing.setTargetLimit(85)
            sailing.setSailingDrop(10)
            sailing.setSailingEnabled(true)

            // Test sequence:
            // 1. Battery at 70% (below resume threshold 75%) -> Charging should be ENABLED
            var snap = BatterySnapshot(percentage: 70, isCharging: true, isACConnected: true)
            sailing.evaluatePowerState(snapshot: snap)
            assert(sailing.currentStatus == .charging, "Test 1 Failed: Should be charging at 70%")
            assert(!smc.isChargingInhibited(), "Test 1 Failed: Charging should NOT be inhibited")
            print("  [Pass] At 70% (< 75%): State = CHARGING. Battery charging is ACTIVE.")

            // 2. Battery charges to 80% (between 75% and 85%) -> Charging should still be ENABLED
            snap.percentage = 80
            sailing.evaluatePowerState(snapshot: snap)
            assert(sailing.currentStatus == .charging, "Test 2 Failed: Should continue charging at 80%")
            assert(!smc.isChargingInhibited(), "Test 2 Failed: Charging should continue")
            print("  [Pass] At 80% (charging up to 85%): State = CHARGING. Target not yet reached.")

            // 3. Battery reaches target limit 85% -> Charging must STOP, Mac must switch to Power Adapter Mode
            snap.percentage = 85
            sailing.evaluatePowerState(snapshot: snap)
            assert(sailing.currentStatus == .sailing, "Test 3 Failed: Should be sailing at 85%")
            assert(sailing.isCurrentlySailing, "Test 3 Failed: isCurrentlySailing must be true")
            assert(smc.isChargingInhibited(), "Test 3 Failed: Charging MUST be inhibited at 85%")
            print("  [Pass] Reached 85% (Target Limit): State = SAILING. Charging STOPPED. Mac runs on AC Power Adapter Mode.")

            // 4. Natural charge drop to 84% -> MUST NOT RECHARGE! Must stay in Sailing Mode (AC bypass)
            snap.percentage = 84
            sailing.evaluatePowerState(snapshot: snap)
            assert(sailing.currentStatus == .sailing, "Test 4 Failed: Should still be sailing at 84%")
            assert(sailing.isCurrentlySailing, "Test 4 Failed: isCurrentlySailing must remain true")
            assert(smc.isChargingInhibited(), "Test 4 Failed: Charging MUST remain inhibited at 84%")
            print("  [Pass] Natural drop to 84%: State = SAILING. Charging remains INHIBITED (NO micro-charge).")

            // 5. Natural charge drop to 80% -> MUST STILL NOT RECHARGE!
            snap.percentage = 80
            sailing.evaluatePowerState(snapshot: snap)
            assert(sailing.currentStatus == .sailing, "Test 5 Failed: Should still be sailing at 80%")
            assert(sailing.isCurrentlySailing, "Test 5 Failed: isCurrentlySailing must remain true")
            assert(smc.isChargingInhibited(), "Test 5 Failed: Charging MUST remain inhibited at 80%")
            print("  [Pass] Natural drop to 80%: State = SAILING. Charging remains INHIBITED (Mac on AC power).")

            // 6. Natural charge drop to 76% -> MUST STILL NOT RECHARGE!
            snap.percentage = 76
            sailing.evaluatePowerState(snapshot: snap)
            assert(sailing.currentStatus == .sailing, "Test 6 Failed: Should still be sailing at 76%")
            assert(sailing.isCurrentlySailing, "Test 6 Failed: isCurrentlySailing must remain true")
            assert(smc.isChargingInhibited(), "Test 6 Failed: Charging MUST remain inhibited at 76%")
            print("  [Pass] Natural drop to 76%: State = SAILING. Charging remains INHIBITED.")

            // 7. Battery drops to 75% (Resume Threshold: 85 - 10 = 75%) -> Charging must RESUME!
            snap.percentage = 75
            sailing.evaluatePowerState(snapshot: snap)
            assert(sailing.currentStatus == .charging, "Test 7 Failed: Charging must resume at 75%")
            assert(!sailing.isCurrentlySailing, "Test 7 Failed: isCurrentlySailing should be false")
            assert(!smc.isChargingInhibited(), "Test 7 Failed: Charging must be re-enabled at 75%")
            print("  [Pass] Battery reached 75% (Resume Threshold): State = CHARGING. Charging is RE-ENABLED.")

            // 8. Unplug AC adapter (switch to battery power)
            snap.isACConnected = false
            sailing.evaluatePowerState(snapshot: snap)
            assert(sailing.currentStatus == .discharging, "Test 8 Failed: Should be discharging when unplugged")
            print("  [Pass] Charger Unplugged: State = DISCHARGING. Mac running on Battery.")

            print("")
            print("========================================================")
            print("  ALL 8 SAILING MODE VERIFICATION TESTS PASSED SUCCESSFULLY! ")
            print("========================================================")

        default:
            print("Unknown command: '\(command)'")
            printHelp()
            exit(1)
        }
    }
}
