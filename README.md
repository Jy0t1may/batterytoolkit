# BatteryToolkit 

### Intelligent Battery Health \& Power Management for macOS (Sequoia \& macOS 27 Compatible)

**BatteryToolkit** is a native macOS menu bar application designed to maximize battery longevity on Apple Silicon and Intel MacBooks. It introduces **Sailing Mode**—a feature that prevents micro-charging cycles and eliminates unnecessary active battery wear by drawing power directly from the AC charger while letting the battery rest.

---

## What is Sailing Mode?

### The Problem with Fixed Charge Limits

Conventional battery limiters force charging to stop at a single threshold (e.g., 85%). However, while plugged into power, modern laptops occasionally experience 1% battery variance due to thermal changes, voltage calibration, or slight discharge. Without a buffer, the moment the battery drops from **85% to 84%**, the charger immediately turns back on to top it back to 85%. This causes constant **micro-charging cycles**, keeping the cells at continuous elevated electrochemical stress.

Furthermore, if a user attempts to cycle between 85% and lower limits by switching to battery power, the battery is actively drained under heavy CPU/GPU workload and recharged repeatedly, drastically increasing overall battery cycle count.

### The Sailing Mode Solution

**Sailing Mode** establishes a dynamic hysteresis buffer:

1. **Target Limit (e.g., 85%)**: When connected to power, the MacBook charges up to 85% and stops.
2. **AC Adapter Bypass (Power Adapter Mode)**: Once 85% is reached, the charging hardware is inhibited (`CH0B` / `CH0C` / `CHTE`), and the Mac is powered **directly by the AC charger**. The battery is electronically idle (0 mA charging current, 0 mA discharge current).
3. **Natural Loss Buffer (e.g., 10% drop ➔ 75%)**: The battery level drops only through natural chemical self-discharge (taking days or weeks if plugged in). The Mac continues running on AC power with charging inhibited.
4. **Recharging Resumes at 75%**: Only when the natural drop reaches the lower resume threshold (85% − 10% = 75%) does charging re-enable, safely bringing the battery back to 85%.

```
   [ Charger Plugged In ]
              │
              ▼
    Charge to 85% (Active)
              │
              ▼  (Hits 85%)
   ┌─────────────────────────────────────────────────────────┐
   │                  SAILING MODE ACTIVE                    │
   │  • Power Status: Powered directly by AC Adapter         │
   │  • Battery Flow: 0.0 W (Charging Current 0 mA)          │
   │  • System Load: Powered directly by AC Adapter          │
   │  • Battery drain: Natural self-discharge only           │
   │  • 84% ... 82% ... 80% ... 78% ... 76% (NO RECHARGE)    │
   └─────────────────────────────────────────────────────────┘
              │
              ▼  (Hits 75% Resume Threshold)
    Recharge to 85% (Cycle repeats)
```

---

## Real-Time Wattage \& Power Flow Telemetry

BatteryToolkit integrates direct telemetry reading from `AppleSmartBattery` to provide live wattage monitoring:

- **Battery Power Flow**:
    - **Charging**: `+15.2 W` (Green/Orange — inflow to battery)
    - **Sailing Mode (AC Bypass)**: `0.0 W (Idle)` (Teal — confirms the battery is NOT charging and NOT draining)
    - **On Battery**: `-12.4 W` (Blue — system discharge rate)
- **System Load Draw**: Total real-time wattage consumed by your Mac’s CPU, GPU, and Display (e.g., `8.3 W`).
- **Charger Rating**: Detected wattage of the attached power adapter (e.g., `8W`, `30W`, `67W`, `96W`, `140W`).
- **Hardware Precision Cycles**: Hardware cycle count queried directly from the battery microcontroller (`Cycle Count: 491`).

---

## Root Causes of Breakage in macOS 27 \& How I Fixed It

### 1. SMC Key Discrepancies \& Rigid Detection

- **The Issue**: In previous versions of Battery Toolkit, the charging key list was strictly hardcoded to `CHTE` and `CH0C`, with a strict metadata check enforcing `dataAttributes == 0xD4`. On macOS 27 and various Apple Silicon hardware revisions (e.g., M2, M3, M4), these keys return different attributes or use alternative registers like `CH0B` (used in AlDente). When the exact match failed, the daemon threw `BTError.unsupported` and halted.
- **Our Fix**: Implemented **dynamic multi-key discovery** in `SMCKit.swift`. The driver probes `CH0B` (AlDente key: `0x02` inhibit, `0x00` charge), `CH0C`, `CHTE`, and `BCLM` (Intel), gracefully selecting the working hardware key.

### 2. Hardcoded Developer ID in XPC Validation

- **The Issue**: `BTXPCValidation.swift` enforced a strict code-signing requirement: `certificate leaf[subject.CN] = "Apple Development: Marvin Häuser (87DYA6FH9K)"`. Any self-compiled or ad-hoc signed build immediately failed XPC client validation, preventing the menu bar app from speaking to the helper daemon.
- **Our Fix**: Unified the architecture with an open, audit-token-based XPC interface (`me.batterytoolkit.helper.mach`) that works seamlessly in local development, ad-hoc signing, and Developer ID signed distributions.

### 3. Sleep \& Power Assertions on macOS 27

- **The Issue**: macOS 27 power management (`powerd`) aggressively attempts to override charging states during system sleep transitions.
- **Our Fix**: Integrated `SleepManager.swift` using `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep)` while charging to target, and releasing it once in Sailing Mode, synchronizing with IOKit power events (`kIOPSNotifyPowerSource`).

---

## Building \& Running

### Prerequisites

- macOS 13.0 or later (fully compatible with macOS Sequoia \& macOS 27)
- Apple Silicon or Intel Mac
- Command Line Tools or Xcode (`swiftc`, `clang`)

### One-Command Build

```
make
```

### Run Automated Sailing Mode Verification Tests

```
make test
```

*Executes all 8 automated hysteresis test scenarios verifying threshold stops, AC adapter bypass, natural discharge buffer, and recharge re-engagement.*

### Check Battery \& Sailing Status via CLI

```
make status
# or
./build/batterytoolkit-cli status
```

### Launch the Menu Bar App

```
make run
# or
open build/BatteryToolkit.app
```

---

## 💻 CLI Commands

The included `batterytoolkit-cli` utility allows complete control from Terminal or automation scripts:

| Command | Description |
| --- | --- |
| `batterytoolkit-cli status` | View battery %, power source, sailing state, and SMC telemetry |
| `batterytoolkit-cli set-limit 85` | Set stop-charging threshold (50% – 100%) |
| `batterytoolkit-cli set-drop 10` | Set sailing drop range (e.g., 10 ➔ resumes at limit - 10) |
| `batterytoolkit-cli sailing-on` | Enable Sailing Mode |
| `batterytoolkit-cli sailing-off` | Disable Sailing Mode (hold strictly at limit) |
| `batterytoolkit-cli charge-full` | Charge to 100% once (e.g. before travel) |
| `batterytoolkit-cli stop` | Inhibit charging immediately (run purely on AC adapter) |
| `batterytoolkit-cli resume` | Resume normal Sailing Mode schedule |
| `batterytoolkit-cli smc-dump` | Probe hardware SMC keys and attributes |
| `batterytoolkit-cli test-sailing` | Run the automated hysteresis verification suite |

---

## 📂 Project Architecture

```
BatteryToolkit/
├── Makefile                          # Build, test, and run automation
├── scripts/
│   └── build_app.sh                  # Compiler script for CLI, helper, and .app
├── src/
│   ├── Common/
│   │   ├── BatteryState.swift        # State models, snapshots, and configuration
│   │   └── SMCProtocols.swift        # XPC interfaces and helper contracts
│   ├── SMC/
│   │   ├── SMCKeys.swift             # Hardware key definitions (CH0B, CH0C, CHTE, BCLM, CHIE)
│   │   └── SMCKit.swift              # Low-level AppleSMC driver with multi-key fallback
│   ├── Core/
│   │   ├── SailingManager.swift      # Sailing Mode state machine & hysteresis logic
│   │   ├── PowerMonitor.swift        # IOKit real-time power notifications observer
│   │   └── SleepManager.swift        # Power assertions & sleep coordination
│   ├── UI/
│   │   ├── AppDelegate.swift         # Menu bar accessory application lifecycle
│   │   ├── StatusItemController.swift# NSStatusItem title/icon manager (⚡️, ⛵️, 🔋)
│   │   └── DashboardViewController.swift # AppKit Popover UI with controls & telemetry
│   ├── Helper/
│   │   ├── BatteryHelper.swift       # Privileged helper daemon implementation
│   │   └── main_helper.swift         # NSXPCListener entry point
│   └── CLI/
│       └── main_cli.swift            # Command line tool & verification suite
└── build/
    ├── BatteryToolkit.app            # Native macOS Application Bundle
    ├── batterytoolkit-cli            # CLI binary
    └── batterytoolkit-helper         # Privileged daemon binary
```

---

## License

Open source under the BSD-3-Clause License.
