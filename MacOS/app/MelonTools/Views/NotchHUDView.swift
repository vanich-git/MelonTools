import SwiftUI

/// The status island above the screen. It hangs from the notch on a narrow
/// neck, stays compact while the pointer is elsewhere, and opens into a wide,
/// low status card on hover or click.
struct NotchHUDView: View {
    @ObservedObject var model: NotchHUDModel
    @ObservedObject private var metrics = NotchHUDMetrics.shared
    @State private var claudeAccounts = 0

    private var snap: NotchHUDMetrics.Snapshot { metrics.snapshot }

    var body: some View {
        card
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onAppear {
                SchedulerStore.shared.start()
                AntigravityPoolStore.shared.start()
                Task { await AntigravityPoolStore.shared.refresh() }
                ModelSourcesStore.shared.load()
                claudeAccounts = ClaudeAuthService.authFiles().count
                Task { await CodexGatewayService.shared.healthCheck() }
            }
    }

    // MARK: - Card

    private var card: some View {
        Group {
            if model.isExpanded {
                expanded
                    .padding(.top, model.topInset)
                    .transition(.opacity)
            } else if model.compactStyle == .sides {
                sideBar
                    .transition(.opacity)
            } else {
                compact
                    .padding(.top, model.topInset)
                    .transition(.opacity)
            }
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
        .background(alignment: .top) { background }
        .clipShape(cardShape)
    }

    private var cardWidth: CGFloat {
        if model.isExpanded {
            return NotchHUDGeometry.expandedSize.width
        }
        return model.compactStyle == .sides ? sideBarWidth : model.compactWidth
    }

    private var cardHeight: CGFloat {
        if model.isExpanded {
            return NotchHUDGeometry.expandedSize.height + model.topInset
        }
        return model.compactStyle == .sides
            ? NotchHUDGeometry.sideBarHeight(topInset: model.topInset)
            : NotchHUDGeometry.compactHeight + model.topInset
    }

    /// The island grows out of the top edge: its top corners are square when
    /// it hangs from a notch (or from the very top of a display without one).
    private var cardShape: AnyShape {
        let topRadius: CGFloat = (model.isExpanded || model.topInset > 0) ? 0 : 18
        // A single bottom radius keeps the shape animation smooth; changing it
        // between compact and expanded made the corners snap.
        return AnyShape(
            UnevenRoundedRectangle(
                topLeadingRadius: topRadius,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 18,
                topTrailingRadius: topRadius,
                style: .continuous
            )
        )
    }

    /// The gradient is anchored to the top edge and keeps a fixed height, so
    /// growing the panel reveals more of it instead of restretching the whole
    /// ramp on every animation tick.
    private var background: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.black, HUDColor.bottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.075), Color.white.opacity(0)],
                        center: UnitPoint(x: 0.5, y: -0.15),
                        startRadius: 0,
                        endRadius: 250
                    )
                )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320, alignment: .top)
        .clipped()
    }

    /// The second resting layout: one continuous black bar across the menu bar,
    /// flush with the top edge. The cut-out in the middle disappears into it.
    private var sideBarWidth: CGFloat {
        model.notchWidth + NotchHUDController.wingWidth * 2 + 8
    }

    private var sideBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                statusDot
                Text(L("5h"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(HUDColor.tertiary)
                Text(percent(snap.hourly))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(HUDColor.primary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(L("7d"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(HUDColor.tertiary)
                Text(percent(snap.weekly))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(HUDColor.primary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            NotchHUDController.shared.setExpanded(true)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(snap.starting ? HUDColor.warn : (snap.running ? HUDColor.ok : HUDColor.tertiary))
            .frame(width: 6, height: 6)
    }

    // MARK: - Compact

    private var compact: some View {
        HStack(spacing: 6) {
            statusDot
            Text(L("5 h"))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(HUDColor.tertiary)
            Text(percent(snap.hourly))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(HUDColor.primary)
            if snap.due > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                    Text("\(snap.due)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(HUDColor.gold)
            }
            Spacer(minLength: 2)
            Text("\(snap.accounts)")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(HUDColor.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            NotchHUDController.shared.setExpanded(true)
        }
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 30)
            hairline
            VStack(alignment: .leading, spacing: 8) {
                poolBlock
                HStack(spacing: 8) {
                    statTile(
                        title: "Antigravity",
                        value: "\(snap.antigravity)",
                        detail: antigravityDetail
                    )
                    statTile(
                        title: L("Providers"),
                        value: "\(providerCount)",
                        detail: L("Connected")
                    )
                }
                scheduleRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Spacer(minLength: 0)
            hairline
            footer
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            statusDot
            Text("Melon Tools")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(HUDColor.primary)
            Spacer(minLength: 4)
            Text(snap.running ? L("running") : L("stopped"))
                .font(.system(size: 9.5))
                .foregroundStyle(snap.running ? HUDColor.ok : HUDColor.tertiary)
            Text("· \(snap.port)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(HUDColor.tertiary)
        }
        .padding(.horizontal, 14)
    }

    private var poolBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(L("Codex pool"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(HUDColor.secondary)
                Spacer(minLength: 4)
                Text(String(format: L("Accounts in pool: %d"), snap.accounts))
                    .font(.system(size: 9.5))
                    .foregroundStyle(HUDColor.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(percent(snap.hourly))
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(HUDColor.primary)
                Text(L("5 h"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(HUDColor.tertiary)
                Spacer(minLength: 4)
                Text(L("Week") + " " + percent(snap.weekly))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(HUDColor.secondary)
            }
            meter
        }
    }

    private var meter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(HUDColor.fill)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [meterColor.opacity(0.75), meterColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, proxy.size.width * quotaFraction))
            }
        }
        .frame(height: 4)
    }

    private func statTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(HUDColor.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(HUDColor.primary)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(HUDColor.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HUDColor.fill)
        )
    }

    private var scheduleRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 10.5))
                .foregroundStyle(HUDColor.secondary)
            Text(L("Scheduler"))
                .font(.system(size: 10.5))
                .foregroundStyle(HUDColor.secondary)
            Spacer(minLength: 4)
            scheduleStatus
        }
    }

    @ViewBuilder
    private var scheduleStatus: some View {
        if snap.runningTask {
            Text(L("Running now"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(HUDColor.gold)
        } else if let next = snap.nextRun {
            HStack(spacing: 3) {
                Text(L("Next run"))
                    .font(.system(size: 10))
                    .foregroundStyle(HUDColor.tertiary)
                Text(next, style: .relative)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(HUDColor.secondary)
            }
        } else {
            Text(L("No tasks"))
                .font(.system(size: 10))
                .foregroundStyle(HUDColor.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            hudButton(
                icon: "macwindow",
                title: L("Open"),
                prominent: true,
                disabled: false,
                help: L("Open Melon Tools")
            ) {
                NotchHUDController.shared.showMainWindow()
            }
            hudButton(
                icon: snap.running ? "pause.fill" : "play.fill",
                title: snap.running ? L("Pause") : L("Start"),
                prominent: false,
                disabled: snap.starting,
                help: snap.running ? L("Pause API") : L("Resume API")
            ) {
                toggleGateway()
            }
            hudButton(
                icon: "forward.end.fill",
                title: L("Run"),
                prominent: false,
                disabled: snap.due == 0 || !snap.running || snap.runningTask,
                help: L("Run next due task")
            ) {
                runNextTask()
            }
        }
        .padding(.horizontal, 10)
    }

    private func hudButton(
        icon: String,
        title: String,
        prominent: Bool,
        disabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? HUDColor.onGold : HUDColor.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? HUDColor.gold : HUDColor.fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.38 : 1)
        .help(help)
    }

    private var hairline: some View {
        Rectangle()
            .fill(HUDColor.hairline)
            .frame(height: 1)
    }

    // MARK: - Data

    private var quotaFraction: Double {
        guard let hourly = snap.hourly, snap.quotaMax > 0 else { return 0 }
        return min(max(hourly / snap.quotaMax, 0), 1)
    }

    private var meterColor: Color {
        guard let hourly = snap.hourly else { return HUDColor.tertiary }
        if hourly < 15 { return HUDColor.danger }
        if hourly < 40 { return HUDColor.warn }
        return HUDColor.ok
    }

    private var providerCount: Int {
        snap.sourceProviders
            + (snap.accounts > 0 ? 1 : 0)
            + (claudeAccounts > 0 ? 1 : 0)
    }

    private var antigravityDetail: String {
        if snap.antigravity == 0 { return "—" }
        if snap.antigravityPaused > 0 {
            return "\(snap.antigravityPaused) " + L("Paused")
        }
        if snap.antigravityCooldown > 0 {
            return "\(snap.antigravityCooldown) " + L("Quarantined")
        }
        return L("Connected")
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func toggleGateway() {
        let gateway = CodexGatewayService.shared
        if gateway.isRunning {
            Task { await gateway.stop() }
        } else {
            let store = CodexStore.shared
            Task {
                await gateway.start(
                    accounts: store.accounts,
                    priorities: store.effectivePriorities()
                )
            }
        }
    }

    private func runNextTask() {
        guard let task = SchedulerPolicy.due(SchedulerStore.shared.tasks, now: Date()).first else {
            return
        }
        Task { await SchedulerStore.shared.runNow(id: task.id) }
    }
}

/// The island is always dark: it reads as part of the top edge, not as a window
/// that follows the app's light/dark appearance setting.
private enum HUDColor {
    static let bottom = Color(hex: 0x121218)
    static let primary = Color.white.opacity(0.96)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.07)
    static let fill = Color.white.opacity(0.06)
    static let gold = Color(hex: 0xF59E0B)
    static let onGold = Color(hex: 0x1A1A1C)
    static let ok = Color(hex: 0x10B981)
    static let warn = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xEF4444)
}
