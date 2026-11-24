import SwiftUI

/// Codex composer chips: live pool chips injected into the Codex app.
struct CodexComposerView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "codex composer",
                    title: L("Composer Chips"),
                    subtitle: L("Composer chips subtitle")
                )
                ComposerChipsCard()
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .mtScrollMemory("scroll.composer")
        }
        .background(MTTheme.background)
    }
}

/// Settings embed and page body: one card for the chips toggle, the live
/// status and the relaunch action.
struct ComposerChipsCard: View {
    @ObservedObject private var bridge = ComposerBridge.shared
    @ObservedObject private var store = CodexStore.shared
    @State private var confirmRelaunch = false
    @AppStorage("composerAutoRelaunch") private var autoRelaunch = false

    var body: some View {
        MTCard(title: L("Composer Chips"), systemImage: "capsule", accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                Toggle(isOn: $bridge.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Show pool chips in the Codex composer"))
                            .font(MTTheme.body(13, weight: .medium))
                            .foregroundStyle(MTTheme.textPrimary)
                        Text(L("Accounts, 5-hour and weekly quota chips in the Codex app input bar."))
                            .font(MTTheme.body(11))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(MTTheme.cyan)

                Toggle(isOn: $autoRelaunch) {
                    Text(L("Automatically relaunch Codex when the chips lose their debug port"))
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .toggleStyle(.switch)
                .tint(MTTheme.cyan)

                Divider().opacity(0.35)

                HStack(spacing: MTTheme.s2) {
                    MTStatusDot(status: statusTint, size: 8)
                    Text(statusTitle)
                        .font(MTTheme.body(12, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: MTTheme.s2)
                    MTGlassButton(title: L("Check now"), systemImage: "arrow.clockwise", tint: MTTheme.cyan, isLoading: bridge.busy) {
                        bridge.verifyNow()
                    }
                    if bridge.status == .codexNotRunning || bridge.status == .noDebugPort {
                        MTGlassButton(title: L("Relaunch Codex with chips"), systemImage: "arrow.triangle.2.circlepath", tint: MTTheme.amber) {
                            confirmRelaunch = true
                        }
                    }
                }

                if let last = bridge.lastAutoRetryAt {
                    Text(L("Last automatic action:") + " " + last.formatted(date: .omitted, time: .shortened))
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textSecondary)
                }

                Text(L("Melon Tools shows live pool chips right inside the Codex window: accounts, 5-hour and weekly quota, and account health."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            store.load()
            if bridge.enabled { bridge.start() }
        }
        .confirmationDialog(L("Quit and relaunch the Codex app?"), isPresented: $confirmRelaunch) {
            Button(L("Quit and relaunch")) { bridge.relaunchCodexWithDebugPort() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The Codex app will quit and reopen - the chips connect right after. Unsaved input may be lost."))
        }
    }

    // MARK: - Status mapping

    private var statusTitle: String {
        switch bridge.status {
        case .off: return L("Disabled")
        case .codexNotRunning: return L("Codex app is not running")
        case .noDebugPort: return L("The Codex app needs a relaunch to show the chips.")
        case .connecting: return L("Looking for the Codex app…")
        case .connected: return L("Connected to the Codex app")
        case .failed: return L("Could not connect to the Codex app.")
        }
    }

    private var statusTint: MTStatus {
        switch bridge.status {
        case .off: return .idle
        case .connected: return .ok
        case .connecting: return .running
        case .codexNotRunning, .noDebugPort, .failed: return .warn
        }
    }
}
