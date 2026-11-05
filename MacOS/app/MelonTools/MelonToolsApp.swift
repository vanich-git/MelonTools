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
    private static let logger = Logger(subsystem: "dev.melontools.app", category: "Lifecycle")
    /// Re-checks for updates while the app runs. The launch check stays in
    /// MainView; this timer only wakes the same throttled code path.
    private var updateTimer: Timer?
    private static let signposter = OSSignposter(
        subsystem: "dev.melontools.app",
        category: "Startup"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XCTest uses this executable as its host. Never read the real vault,
        // rewrite ~/.codex, start the gateway or start the local engine during
        // tests.
        guard !AppRuntime.isTesting else { return }
        prepareLocalAI()
        Self.logger.info("launched \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
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
                // The island only reads cached state; show it with the first
                // frame instead of waiting for catalog and composer startup.
                NotchHUDController.shared.start()
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

    /// Loads the local registry and clears a router left behind by a crash.
    /// It deliberately does not start llama-server or load a model: the user
    /// starts a model explicitly from Local AI, so launching Melon Tools does
    /// not spend gigabytes of RAM before the first request.
    private func prepareLocalAI() {
        Task { @MainActor in
            // Snapshot user data before 6.0.0 rewrites anything (§19).
            LocalAIMigration.runIfNeeded()
            RuntimeStore.shared.reload()
            // A previous crash can leave the router holding a model; clear it
            // before the user starts a fresh one. The reap now runs off the
            // main actor (async), so the first frame is not held by pgrep.
            await LocalInferenceService.shared.reapOrphanedEngines()
            LocalModelStore.shared.loadRegistry()
            // Drop leftovers of a crash or force-quit. Resumable download parts
            // are kept: their sidecar is the only thing that makes a retry safe.
            LocalAIMigration.runMaintenance(
                activeDownloadJobs: Set(LocalDownloadManager.shared.items.map(\.jobID))
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.info("terminating")
        MainActor.assumeIsolated {
            updateTimer?.invalidate()
            updateTimer = nil
            CodexStore.shared.flushSave()
            // The scheduler writes on a background queue now; quitting must
            // not drop the last run, its history or the daily token counter.
            SchedulerStore.shared.flushSave()
            QuotaHistoryStore.shared.flush()
            ComposerBridge.shared.shutdownForQuit()
            // A llama-server left behind keeps gigabytes of model weights
            // resident and answers on a port the app no longer tracks, so it
            // must not survive a clean quit.
            LocalInferenceService.shared.stopSync()
            if UserDefaults.standard.bool(forKey: "gatewayStopOnQuit") {
                CodexGatewayService.shared.stopSync()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep living in the menu bar
    }
}
