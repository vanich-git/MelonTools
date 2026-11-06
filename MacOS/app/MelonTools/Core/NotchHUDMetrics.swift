import Combine
import Foundation

/// The small subset of app state the island renders. Subscribing to the whole
/// stores made the HUD redraw on every QoS sample and busy-account change; this
/// snapshot only publishes when one of the visible values actually changes.
@MainActor
final class NotchHUDMetrics: ObservableObject {
    struct Snapshot: Equatable {
        var running = false
        var starting = false
        var port = 0
        var accounts = 0
        var hourly: Double?
        var weekly: Double?
        var quotaMax = 0.0
        var due = 0
        var nextRun: Date?
        var runningTask = false
        var antigravity = 0
        var antigravityPaused = 0
        var antigravityCooldown = 0
        var sourceProviders = 0
        var language = "ru"
    }

    static let shared = NotchHUDMetrics()

    @Published private(set) var snapshot = Snapshot()
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false

    private init() {
        snapshot = makeSnapshot()
        observe()
    }

    private func observe() {
        CodexStore.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        CodexGatewayService.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        SchedulerStore.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        AntigravityPoolStore.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        ModelSourcesStore.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        L10n.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    /// `objectWillChange` fires before the value changes; one main-actor hop
    /// later the new value is readable. Coalesces bursts (QoS, scheduler ticks).
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let next = makeSnapshot()
        guard next != snapshot else { return }
        snapshot = next
    }

    private func makeSnapshot() -> Snapshot {
        let now = Date()
        let accounts = CodexStore.shared.accounts.filter { $0.poolEnabled != false }
        let totals = DashboardMetrics.quotaTotals(accounts: accounts)
        let due = SchedulerPolicy.due(SchedulerStore.shared.tasks, now: now)
        let antigravity = AntigravityPoolStore.shared.accounts
        let sources = ModelSourcesStore.shared.sources

        var snapshot = Snapshot()
        snapshot.running = CodexGatewayService.shared.isRunning
        snapshot.starting = CodexGatewayService.shared.isStarting
        snapshot.port = CodexGatewayService.shared.port
        snapshot.accounts = accounts.count
        snapshot.hourly = totals.hourly
        snapshot.weekly = totals.weekly
        snapshot.quotaMax = totals.max
        snapshot.due = due.count
        snapshot.nextRun = DashboardMetrics.nextRun(tasks: SchedulerStore.shared.tasks)
        snapshot.runningTask = SchedulerStore.shared.runningTaskID != nil
        snapshot.antigravity = antigravity.count
        snapshot.antigravityPaused = antigravity.filter(\.isPaused).count
        snapshot.antigravityCooldown = antigravity.filter { $0.activeCooldown != nil }.count
        snapshot.sourceProviders = sources.filter { source in
            !source.title.isEmpty
                && source.enabled
                && (!source.selectedModels.isEmpty
                    || source.kind == .claude
                    || source.kind == .antigravity)
        }.count
        snapshot.language = L10n.shared.code
        return snapshot
    }
}
