import AppKit
import SwiftUI

struct LocalAIView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case models = "Models"
        case catalog = "Hugging Face"
        case downloads = "Downloads"
        case runtime = "Runtime"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .models: return "cube.fill"
            case .catalog: return "globe.badge.chevron.backward"
            case .downloads: return "arrow.down.circle.fill"
            case .runtime: return "cpu.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @State private var selectedTab: Tab = .models
    /// Screens stay mounted once visited so their `@State` (query, selection,
    /// drafts, focus) survives a tab switch. A `switch` recreated the view and
    /// silently dropped the Hugging Face search and the selected repository.
    @State private var visitedTabs: Set<Tab> = [.models]
    @ObservedObject private var downloadManager = LocalDownloadManager.shared
    @ObservedObject private var runtime = LocalInferenceService.shared
    @ObservedObject private var modelStore = LocalModelStore.shared

    var activeDownloadsCount: Int {
        downloadManager.items.filter { $0.state == .downloading || $0.state == .queued }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented Header Bar
            HStack(spacing: MTTheme.s3) {
                ForEach(Tab.allCases) { tab in
                    Button(action: {
                        visitedTabs.insert(tab)
                        selectedTab = tab
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11, weight: .semibold))

                            Text(L(tab.rawValue))
                                .font(MTTheme.body(12, weight: selectedTab == tab ? .semibold : .medium))

                            if tab == .downloads && activeDownloadsCount > 0 {
                                Text("\(activeDownloadsCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(MTTheme.emerald)
                                    .clipShape(Capsule())
                            }

                            if tab == .runtime && runtime.status.isRunning {
                                Circle()
                                    .fill(MTTheme.emerald)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            selectedTab == tab
                            ? Color.primary.opacity(0.1)
                            : Color.primary.opacity(0.02)
                        )
                        .cornerRadius(8)
                        .foregroundStyle(selectedTab == tab ? MTTheme.textPrimary : MTTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Engine status indicator
                HStack(spacing: 6) {
                    if runtime.status.isRunning {
                        MTStatusDot(status: .ok)
                        if let model = runtime.currentModel {
                            Text(model.displayName)
                                .font(MTTheme.body(11, weight: .semibold))
                                .foregroundStyle(MTTheme.emerald)
                                .lineLimit(1)
                        } else {
                            Text(L("Online"))
                                .font(MTTheme.body(11, weight: .semibold))
                                .foregroundStyle(MTTheme.emerald)
                        }
                    } else if runtime.status.isStarting {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                            .frame(width: 11, height: 11)
                        Text(L("Loading engine..."))
                            .font(MTTheme.body(11, weight: .semibold))
                            .foregroundStyle(MTTheme.amber)
                            .lineLimit(1)
                    } else {
                        MTStatusDot(status: .idle)
                        Text(L("Standby"))
                            .font(MTTheme.body(11))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(6)
            }
            .padding(.horizontal, MTTheme.s4)
            .padding(.vertical, MTTheme.s3)
            .background(Color.primary.opacity(0.02))

            Divider().background(Color.primary.opacity(0.08))

            if let error = modelStore.registryError {
                VStack(alignment: .leading, spacing: MTTheme.s2) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(MTTheme.amber)
                    HStack {
                        Button(L("Retry")) { modelStore.loadRegistry() }
                        Button(L("Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                modelStore.registryBackupURL ?? modelStore.registryFileURL
                            ])
                        }
                    }
                }
                .font(MTTheme.body(12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MTTheme.s3)
            }

            // Tab Content. Every visited screen keeps its identity and state;
            // only the active one is visible and hit-testable.
            ZStack {
                ForEach(Tab.allCases) { tab in
                    if visitedTabs.contains(tab) {
                        content(for: tab)
                            .opacity(selectedTab == tab ? 1 : 0)
                            .allowsHitTesting(selectedTab == tab)
                            // Disabled as well as hidden: a mounted screen keeps
                            // its `@State`, but its keyboard shortcuts (Cmd-F)
                            // must not fire from a tab the user is not on.
                            .disabled(selectedTab != tab)
                            .accessibilityHidden(selectedTab != tab)
                            .zIndex(selectedTab == tab ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One keyboard/focus rule for every Local AI screen: Esc drops the
            // keyboard focus back to the window when no field claims it. Screens
            // with a search field (Hugging Face) clear it first in their own
            // `onExitCommand`; Cmd-F focuses the active screen's search field.
            .onExitCommand {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .background(MTTheme.background)
    }

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        case .models:
            LocalModelsView()
        case .catalog:
            HuggingFaceCatalogView(isActive: selectedTab == .catalog)
        case .downloads:
            LocalDownloadsView()
        case .runtime:
            LocalRuntimeView()
        case .settings:
            LocalAISettingsTab()
        }
    }
}
