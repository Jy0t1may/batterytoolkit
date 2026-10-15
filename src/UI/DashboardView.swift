//
//  DashboardView.swift
//  BatteryToolkit - Modern SwiftUI Popover Dashboard with Real-time Telemetry & Animations
//

import SwiftUI
import Combine

public final class DashboardViewModel: ObservableObject, @unchecked Sendable {
    public static let shared = DashboardViewModel()

    @Published public var percentage: Int = 100
    @Published public var isCharging: Bool = false
    @Published public var isACConnected: Bool = true
    @Published public var isSailing: Bool = false
    @Published public var statusDescription: String = "Initializing..."
    @Published public var currentStatus: ChargingStatus = .discharging
    @Published public var currentMode: ChargingMode = .sailing

    @Published public var targetLimit: Double = 85
    @Published public var sailingDrop: Double = 10
    @Published public var sailingEnabled: Bool = true

    // Telemetry & Wattage
    @Published public var watts: Double = 0.0
    @Published public var systemLoadWatts: Double = 0.0
    @Published public var adapterWatts: Int = 0
    @Published public var activeSMCKey: String = "Apple Silicon PMU"
    @Published public var architecture: String = "Apple Silicon"
    @Published public var cycleCount: Int = 0
    @Published public var temperature: Double = 25.0
    @Published public var voltage: Double = 12.0
    @Published public var amperage: Int = 0

    // Action Feedback Banner
    @Published public var actionFeedback: String? = nil

    private var observerUUID: UUID?

    public var resumeThreshold: Int {
        return max(20, Int(targetLimit - sailingDrop))
    }

    private init() {
        let settings = SailingManager.shared.settings
        self.targetLimit = Double(settings.targetLimit)
        self.sailingDrop = Double(settings.sailingDrop)
        self.sailingEnabled = settings.sailingEnabled
        self.currentMode = SailingManager.shared.currentMode

        // Register as multicast observer of SailingManager
        self.observerUUID = SailingManager.shared.addObserver { [weak self] status, desc, snapshot in
            self?.updateFromSnapshot(status: status, desc: desc, snapshot: snapshot)
        }

        refresh()
    }

    deinit {
        if let id = observerUUID {
            SailingManager.shared.removeObserver(id)
        }
    }

    public func refresh() {
        let snapshot = PowerMonitor.shared.getCurrentSnapshot()
        SailingManager.shared.evaluatePowerState(snapshot: snapshot)
        updateFromSnapshot(
            status: SailingManager.shared.currentStatus,
            desc: SailingManager.shared.statusDescription,
            snapshot: snapshot
        )
    }

    private func updateFromSnapshot(status: ChargingStatus, desc: String, snapshot: BatterySnapshot) {
        self.percentage = snapshot.percentage
        self.isCharging = snapshot.isCharging
        self.isACConnected = snapshot.isACConnected
        self.isSailing = SailingManager.shared.isCurrentlySailing
        self.statusDescription = desc
        self.currentStatus = status
        self.currentMode = SailingManager.shared.currentMode

        self.watts = snapshot.watts
        self.systemLoadWatts = snapshot.systemLoadWatts
        self.adapterWatts = snapshot.adapterWatts
        self.activeSMCKey = snapshot.activeSMCKey
        self.architecture = snapshot.architecture
        self.cycleCount = snapshot.cycleCount
        self.temperature = snapshot.temperature
        self.voltage = snapshot.voltage
        self.amperage = snapshot.amperage
    }

    public func applyTargetLimit(_ value: Double) {
        let intVal = Int(value)
        self.targetLimit = Double(intVal)
        SailingManager.shared.setTargetLimit(intVal)
        showFeedback("Stop limit set to \(intVal)%")
    }

    public func applySailingDrop(_ value: Double) {
        let intVal = Int(value)
        self.sailingDrop = Double(intVal)
        SailingManager.shared.setSailingDrop(intVal)
        showFeedback("Resume threshold set to \(resumeThreshold)%")
    }

    public func toggleSailingMode(_ enabled: Bool) {
        self.sailingEnabled = enabled
        SailingManager.shared.setSailingEnabled(enabled)
        showFeedback(enabled ? "Sailing Mode Enabled" : "Direct Limit Mode Enabled")
    }

    public func chargeTo100Once() {
        SailingManager.shared.chargeToFullOnce()
        showFeedback("⚡️ Initiated one-time charge to 100%")
    }

    public func stopChargingNow() {
        SailingManager.shared.stopChargingNow()
        showFeedback("🛑 Charging inhibited - running on AC power")
    }

    public func resumeNormalSchedule() {
        SailingManager.shared.resumeNormalSchedule()
        showFeedback("⛵️ Resumed Sailing Mode schedule")
    }

    private func showFeedback(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            self.actionFeedback = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            withAnimation(.easeInOut(duration: 0.25)) {
                if self?.actionFeedback == text {
                    self?.actionFeedback = nil
                }
            }
        }
    }
}

public struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    public init(viewModel: DashboardViewModel = .shared) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // 1. Header Card (Battery Ring + Status Badge)
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 6)
                        .frame(width: 52, height: 52)
                    Circle()
                        .trim(from: 0, to: CGFloat(viewModel.percentage) / 100.0)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 52, height: 52)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: viewModel.percentage)

                    Text("\(viewModel.percentage)%")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("BatteryToolkit")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    statusBadgeView
                }
            }

            // 2. Status Description Banner
            Text(viewModel.statusDescription)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)

            // 3. Idea 1: Real-time Wattage & Power Flow Telemetry Card
            wattageTelemetryCard

            Divider()

            // 4. Sailing Mode Toggle Row
            Toggle(isOn: Binding(
                get: { viewModel.sailingEnabled },
                set: { viewModel.toggleSailingMode($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sailing Mode")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Prevents micro-cycles by running on AC power")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(SwitchToggleStyle())

            // 5. Charge Limit Slider
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Stop Charging Threshold")
                        .font(.system(size: 11))
                    Spacer()
                    Text("\(Int(viewModel.targetLimit))%")
                        .font(.system(size: 11.5, weight: .bold))
                }

                Slider(
                    value: Binding(
                        get: { viewModel.targetLimit },
                        set: { viewModel.applyTargetLimit($0) }
                    ),
                    in: 50...100,
                    step: 1
                )
            }

            // 6. Sailing Drop Slider
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Sailing Drop Range")
                        .font(.system(size: 11))
                    Spacer()
                    Text("\(Int(viewModel.sailingDrop))% (Resumes at \(viewModel.resumeThreshold)%)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.teal)
                }

                Slider(
                    value: Binding(
                        get: { viewModel.sailingDrop },
                        set: { viewModel.applySailingDrop($0) }
                    ),
                    in: 2...25,
                    step: 1
                )

                Text("Stops charging at \(Int(viewModel.targetLimit))%. Mac stays on AC charger. Natural discharge down to \(viewModel.resumeThreshold)% before recharging.")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 7. Action Buttons with Spring Animations & Active Mode Highlight (Issue 3)
            HStack(spacing: 8) {
                actionButton(
                    title: "100% Once",
                    icon: "bolt.fill",
                    isActive: viewModel.currentMode == .fullChargeOnce,
                    activeColor: .orange
                ) {
                    viewModel.chargeTo100Once()
                }

                actionButton(
                    title: "Inhibit (AC)",
                    icon: "pause.fill",
                    isActive: viewModel.currentMode == .manualHold,
                    activeColor: .red
                ) {
                    viewModel.stopChargingNow()
                }

                actionButton(
                    title: "Resume",
                    icon: "play.fill",
                    isActive: viewModel.currentMode == .sailing && !viewModel.isCharging,
                    activeColor: .teal
                ) {
                    viewModel.resumeNormalSchedule()
                }
            }

            // Optional Animated Action Feedback Toast
            if let feedback = viewModel.actionFeedback {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(feedback)
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.12))
                .cornerRadius(6)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Divider()

            // 8. Hardware Telemetry Card (Issue 4: Cycle count & SMC keys)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("SMC Control: \(viewModel.activeSMCKey)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Cycles: \(viewModel.cycleCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                }

                HStack {
                    Text("Hardware: \(viewModel.architecture) | Temp: \(String(format: "%.1f°C", viewModel.temperature))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(15)
        .frame(width: 340)
        .onReceive(timer) { _ in
            viewModel.refresh()
        }
    }

    // MARK: - Subviews & Helpers

    @ViewBuilder
    private var wattageTelemetryCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(wattageHeader)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Text(wattageValue)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(wattageColor)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("System Load")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Text(String(format: "%.1f W", viewModel.systemLoadWatts))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
            }

            if viewModel.adapterWatts > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Charger")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("\(viewModel.adapterWatts)W")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    private var wattageHeader: String {
        if viewModel.currentStatus == .sailing {
            return "Battery Power (Sailing)"
        } else if viewModel.isCharging {
            return "Battery Charging Power"
        } else {
            return "Battery Drain Rate"
        }
    }

    private var wattageValue: String {
        if viewModel.currentStatus == .sailing {
            return "0.0 W (Idle)"
        } else if viewModel.isCharging {
            return String(format: "+%.1f W", viewModel.watts)
        } else {
            return String(format: "-%.1f W", viewModel.watts)
        }
    }

    private var wattageColor: Color {
        if viewModel.currentStatus == .sailing {
            return .teal
        } else if viewModel.isCharging {
            return .orange
        } else {
            return .blue
        }
    }

    private func actionButton(
        title: String,
        icon: String,
        isActive: Bool,
        activeColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                action()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: isActive ? .bold : .medium))
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(isActive ? activeColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .foregroundColor(isActive ? activeColor : .primary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? activeColor : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    private var ringColor: Color {
        switch viewModel.currentStatus {
        case .sailing: return .teal
        case .charging: return .orange
        case .discharging: return .blue
        case .charged: return .green
        case .paused: return .red
        case .unsupported: return .gray
        }
    }

    @ViewBuilder
    private var statusBadgeView: some View {
        switch viewModel.currentStatus {
        case .sailing:
            badge(text: "⛵️ Sailing (AC Powered)", color: .teal)
        case .charging:
            badge(text: "⚡️ Charging to \(Int(viewModel.targetLimit))%", color: .orange)
        case .discharging:
            badge(text: "🔋 On Battery Power", color: .blue)
        case .charged:
            badge(text: "✓ Holding at Limit", color: .green)
        case .paused:
            badge(text: "🛑 Charging Inhibited", color: .red)
        case .unsupported:
            badge(text: "⚠️ Hardware Restricted", color: .gray)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .cornerRadius(5)
    }
}
