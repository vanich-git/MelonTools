import AppKit
import SwiftUI
import os

@main
struct MelonToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var l10n = L10n.shared

    var body: some Scene {
        Window("Melon Tools", id: "main") {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 1060, minHeight: 680)
                .id(l10n.code) // full re-render on language switch
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .id(l10n.code)
        } label: {
            Image(nsImage: MelonAssets.menuBarLogo)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .id(l10n.code)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Re-checks for updates while the app runs. The launch check stays in
    /// MainView; this timer only wakes the same throttled code path.
    private var updateTimer: Timer?
    private static let signposter = OSSignposter(
        subsystem: "dev.melontools.app",
        category: "Startup"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XCTest uses this executable as its host. Never read the real vault,
        // rewrite ~/.codex, start the gateway or relaunch Codex during tests.
        guard !AppRuntime.isTesting else { return }
        MainActor.assumeIsolated {
            // Everything below used to run before the first frame: the vault
            // read, a catalog write, three timers and the gateway start all
            // delayed the window. Yield once so SwiftUI can commit its first
            // frame, then load in small signposted phases.
            Task { @MainActor [weak self] in
                await Task.yield()
                let startup = Self.signposter.beginInterval("Startup")
                // The catalog filter and the picker index read the account pool
                // and its per-account selection: load the vault and the pooled
                // models before the catalog is regenerated.
                CodexStore.shared.load()
                CodexPoolModelsStore.shared.refresh()
                CodexStore.shared.startQuotaScheduler()
                SchedulerStore.shared.start()
                Self.signposter.endInterval("Startup", startup)

                let catalog = Self.signposter.beginInterval("CatalogSync")
                ModelSourcesStore.shared.syncCatalogIfNeeded()
                Self.signposter.endInterval("CatalogSync", catalog)

                let composer = Self.signposter.beginInterval("ComposerStart")
                ComposerBridge.shared.start()
                self?.startUpdateTimer()
                Self.signposter.endInterval("ComposerStart", composer)

                let autoStart = UserDefaults.standard.object(forKey: "gatewayAutoStart") as? Bool ?? true
                // The Go split must be known before the gateway writes its
                // config: Go models route through the /go endpoints.
                await ModelSourcesStore.shared.refreshOpenCodeGoAccess()
                guard autoStart else { return }
                let gateway = Self.signposter.beginInterval("GatewayStart")
                await CodexGatewayService.shared.start(
                    accounts: CodexStore.shared.accounts,
                    priorities: CodexStore.shared.effectivePriorities()
                )
                Self.signposter.endInterval("GatewayStart", gateway)
            }
        }
    }

    /// Fires every hour; `check(manual: false)` is a no-op until an hour has
    /// passed since the last successful check.
    private func startUpdateTimer() {
        updateTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: UpdaterStore.periodicCheckInterval, repeats: true) { _ in
            Task { @MainActor in
                await UpdaterStore.shared.check(manual: false)
            }
        }
        timer.tolerance = 60
        updateTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            updateTimer?.invalidate()
            updateTimer = nil
            CodexStore.shared.flushSave()
            QuotaHistoryStore.shared.flush()
            ComposerBridge.shared.shutdownForQuit()
            if UserDefaults.standard.bool(forKey: "gatewayStopOnQuit") {
                CodexGatewayService.shared.stopSync()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep living in the menu bar
    }
}
