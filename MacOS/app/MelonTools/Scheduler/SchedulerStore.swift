import Combine
import Foundation
import UserNotifications

// MARK: - Local notifications

/// One authorization prompt and one delivery path for the whole app. Both the
/// scheduler and the Codex quota watcher use this helper, so the user answers
/// the system prompt at most once per session.
@MainActor
enum MTNotificationCenter {
    private static var authorizationRequested = false

    static func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, identifier: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }
}

/// Pure task-run notification content. Success shows the task name and the
/// first 120 characters of the result; failure keeps the error prefix verbatim.
enum SchedulerNotificationPolicy {
    static let enabledKey = "taskNotifications"
    static let previewLength = 120

    struct Notice: Equatable {
        let title: String
        let body: String
        let identifier: String
    }

    static func notice(
        taskId: String,
        taskName: String,
        status: SchedulerTaskStatus,
        result: String,
        error: String?,
        now: Date = Date()
    ) -> Notice? {
        let title: String
        let payload: String
        switch status {
        case .ok:
            title = L("Scheduled task finished")
            payload = preview(result)
        case .error:
            title = L("Scheduled task failed")
            payload = preview(error ?? "")
        // Cancellation is user-initiated: no notification.
        case .never, .running, .cancelled:
            return nil
        }
        let body = payload.isEmpty ? taskName : "\(taskName): \(payload)"
        return Notice(
            title: title,
            body: body,
            identifier: "task-\(taskId)-\(Int(now.timeIntervalSince1970))"
        )
    }

    /// First `previewLength` characters, with an ellipsis when the text is
    /// longer. No other normalization: error text stays verbatim.
    static func preview(_ text: String, limit: Int = previewLength) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

/// Delivery seam: production posts a system notification, tests inject a
/// recorder or a disabled sink.
struct SchedulerNotificationSink {
    var isEnabled: @MainActor () -> Bool
    var post: @MainActor (SchedulerNotificationPolicy.Notice) -> Void

    static let system = SchedulerNotificationSink(
        isEnabled: {
            UserDefaults.standard.object(forKey: SchedulerNotificationPolicy.enabledKey) as? Bool ?? true
        },
        post: { notice in
            MTNotificationCenter.post(
                title: notice.title,
                body: notice.body,
                identifier: notice.identifier
            )
        }
    )

    static let disabled = SchedulerNotificationSink(
        isEnabled: { false },
        post: { _ in }
    )
}

/// Serialized, off-main writer for the scheduler files.
///
/// Encoding and I/O must not run on the main actor: `scheduler.json` carries
/// the whole history (potentially ~12.8 MB of result bodies) and every run,
/// edit and day rollover rewrote it synchronously, which stalled the UI. A
/// serial queue preserves write order, and the pending map collapses a burst
/// of saves into “the newest snapshot wins”, so a 1-minute task cannot pile up
/// unbounded I/O behind the UI.
final class SchedulerPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.melontools.scheduler.persistence", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: () throws -> Data] = [:]
    /// FIFO of files with a pending payload; a URL appears at most once.
    private var order: [URL] = []
    private var draining = false
    private var failureHandler: (@Sendable (String) -> Void)?

    func onFailure(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        failureHandler = handler
        lock.unlock()
    }

    /// Queue one snapshot for `url`. An older pending payload for the same
    /// file is dropped: it would be overwritten anyway.
    func submit(url: URL, encode: @escaping () throws -> Data) {
        lock.lock()
        if pending[url] == nil { order.append(url) }
        pending[url] = encode
        let alreadyDraining = draining
        if !alreadyDraining { draining = true }
        lock.unlock()
        guard !alreadyDraining else { return }
        queue.async { [self] in drain() }
    }

    /// Replace the pending writes without blocking; the caller is about to
    /// read the files and must not rewrite them behind its own back.
    func discardPending() {
        lock.lock()
        pending.removeAll()
        order.removeAll()
        lock.unlock()
    }

    /// Wait for the in-flight write (and every queued one) to finish. Used on
    /// quit and by tests that read the file right after a mutation.
    func flush() {
        queue.sync { drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            let url = order.first
            if let url { order.removeFirst() }
            let encode = url.flatMap { pending.removeValue(forKey: $0) }
            let handler = failureHandler
            if encode == nil {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            guard let url, let encode else { continue }
            do {
                let data = try encode()
                try SecureFile.write(data, to: url)
            } catch {
                handler?("Could not save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}

/// Why a backup restore could not take ownership of the scheduler files.
enum SchedulerRestoreError: Error, Equatable, LocalizedError {
    case runInProgress

    var errorDescription: String? {
        switch self {
        case .runInProgress:
            return L("A scheduled task is running. Wait for it to finish, then restore the backup again.")
        }
    }
}

/// Task scheduler store: CRUD, persistence, the 30 s tick and the serial run
/// queue. The file is `~/Library/Application Support/MelonTools/scheduler.json`
/// written atomically with mode 0600 through `SecureFile`.
///
/// Nothing runs unless the app process is alive — there is no launchd agent,
/// no background helper and no retry queue. A stopped gateway only pauses
/// scheduled ticks; when it is running again the next tick starts from the
/// current time, so a downtime can never turn into a burst.
@MainActor
final class SchedulerStore: ObservableObject {
    static let shared = SchedulerStore()

    @Published private(set) var tasks: [SchedulerTask] = []
    @Published private(set) var history: [SchedulerHistoryEntry] = []
    /// Non-nil while one task is in flight; the runner is strictly serial.
    @Published private(set) var runningTaskID: String?
    /// Manual `Run now` requests waiting for the active run, in order. Memory
    /// only: the queue never survives an app restart.
    @Published private(set) var queuedTaskIDs: [String] = []
    /// True between `cancelCurrent()` and the end of the active run.
    @Published private(set) var isCancelling = false
    @Published private(set) var models: [String] = []
    @Published private(set) var modelsError: String?
    @Published private(set) var isLoadingModels = false
    @Published private(set) var persistenceError: String?

    private let fileURL: URL
    private let usageURL: URL
    private let runner: SchedulerRunner
    private let catalog: SchedulerModelCatalog
    private let gatewayOverride: SchedulerGateway?
    private let gatewayRunningOverride: Bool?
    private let notifications: SchedulerNotificationSink
    private let poolGuard: ((SchedulerTask) -> Bool)?
    private let persistence = SchedulerPersistence()
    /// Atomic writer seam: tests inject a failure without touching the disk.
    private let usageWrite: (Data, URL) throws -> Void
    /// Durable budget counter. `history` stays the bounded UI log.
    private var ledger = SchedulerUsageLedger()
    private var timer: Timer?
    private var loaded = false
    /// A newer build wrote scheduler.json; keep it untouched.
    private var readOnly = false
    /// A backup restore is replacing the files: no write and no new run may
    /// run against the pre-restore in-memory state.
    private var backupRestoreSuspended = false
    /// Today's budget is unknown (unreadable/newer/impossible counter). Tasks
    /// with a daily limit refuse to spend until the file is recovered.
    private(set) var usageBudgetFailClosed = false
    /// The usage file must not be rewritten: a newer build wrote it, it could
    /// not be read, or it failed validation. Only an explicit recovery (restore
    /// or remove the file) clears this.
    private var usageReadOnly = false
    /// The last durable write of the counter failed. Budgets stay paused, but a
    /// later write attempt is allowed once the disk is writable again.
    private var usageWriteFailed = false
    /// Handle of the one in-flight run, so `cancelCurrent()` can stop it.
    private var activeRun: Task<Bool, Never>?

    init(
        fileURL: URL = SchedulerStore.defaultFileURL(),
        runner: SchedulerRunner = SchedulerRunner(),
        catalog: SchedulerModelCatalog = SchedulerModelCatalog(),
        gateway: SchedulerGateway? = nil,
        isGatewayRunning: Bool? = nil,
        notifications: SchedulerNotificationSink = .system,
        poolGuard: ((SchedulerTask) -> Bool)? = nil,
        usageFileURL: URL? = nil,
        usageWrite: @escaping (Data, URL) throws -> Void = { try SecureFile.write($0, to: $1) }
    ) {
        self.fileURL = fileURL
        self.usageWrite = usageWrite
        self.usageURL = usageFileURL ?? fileURL.deletingLastPathComponent()
            .appendingPathComponent("scheduler-usage.json")
        self.runner = runner
        self.catalog = catalog
        self.gatewayOverride = gateway
        self.gatewayRunningOverride = isGatewayRunning
        self.notifications = notifications
        self.poolGuard = poolGuard
        persistence.onFailure { [weak self] message in
            Task { @MainActor in self?.persistenceError = message }
        }
    }

    /// Account-pool models need at least one usable Codex account; namespaced
    /// provider models route independently and are not blocked by the pool.
    static func poolAllows(_ task: SchedulerTask) -> Bool {
        if AppRuntime.isTesting { return true }
        if task.model.contains("/")
            || task.model.hasPrefix("claude-")
            || AntigravityModelRegistry.ids.contains(task.model) {
            return true
        }
        return CodexStore.shared.accounts.contains {
            CodexRoutingPlanner.blockReason($0) == nil
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        CodexStore.supportDir.appendingPathComponent("scheduler.json")
    }

    private var currentGateway: SchedulerGateway {
        gatewayOverride ?? SchedulerGateway(
            baseURL: CodexGatewayService.shared.baseURL,
            apiKey: CodexGatewayService.shared.apiKey
        )
    }

    private var gatewayIsRunning: Bool {
        gatewayRunningOverride ?? CodexGatewayService.shared.isRunning
    }

    var isRunning: Bool { runningTaskID != nil }

    // MARK: - Lifecycle

    /// Load the file once, then arm the 30 s timer and run one overdue task.
    /// Calling it again (dashboard, menu bar, scheduler page) is a no-op.
    func start() {
        if !loaded { load() }
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: SchedulerLimits.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.tick()
            }
        }
        timer.tolerance = SchedulerLimits.tickTolerance
        self.timer = timer
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Persistence

    func load(now: Date = Date()) {
        loaded = true
        readOnly = false
        // A snapshot queued before this read belongs to the state being
        // replaced (a restore, a relaunch). Writing it afterwards would
        // resurrect the old file over the one we just read.
        persistence.discardPending()
        persistence.flush()
        let needsUsageSeed = loadLedger(now: now)
        guard let data = SecureFile.read(fileURL) else {
            tasks = []
            history = []
            // A budget failure is still relevant on a fresh task file; do not
            // hide it behind a successful (empty) scheduler read.
            if !usageBudgetFailClosed { persistenceError = nil }
            if needsUsageSeed { saveLedger() }
            return
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["schemaVersion"] as? Int,
           version > PersistenceSchema.current {
            readOnly = true
            tasks = []
            history = []
            persistenceError = "This scheduler file was written by a newer Melon Tools. Update the app before editing tasks."
            return
        }
        do {
            let file = try JSONDecoder().decode(SchedulerFile.self, from: data)
            var restored = file.tasks
            var changed = false
            for index in restored.indices {
                // A task that was mid-run when the app quit has no live
                // process behind it any more.
                if restored[index].lastStatus == .running {
                    restored[index].lastStatus = .error
                    restored[index].lastError = restored[index].lastError
                        ?? "Interrupted: Melon Tools quit while the task was running."
                    // Do not replay a run that was interrupted mid-flight.
                    restored[index].nextRunAt = restored[index].enabled
                        ? SchedulerPolicy.nextRun(after: now, task: restored[index])?.timeIntervalSince1970
                        : nil
                    changed = true
                }
                // An enabled task without a schedule (hand-edited file) gets
                // the next fire of its own kind instead of running
                // immediately.
                if restored[index].enabled, restored[index].nextRunAt == nil {
                    restored[index].nextRunAt = SchedulerPolicy.nextRun(
                        after: now,
                        task: restored[index]
                    )?.timeIntervalSince1970
                    changed = true
                }
            }
            let trimmed = SchedulerPolicy.trimHistory(file.history)
            tasks = restored
            history = trimmed
            // One-time migration: files written before the ledger existed have
            // no usage counter. Seed today's total from the surviving history
            // (a lower bound) so the first run after the upgrade cannot reset
            // an already-spent budget.
            if needsUsageSeed {
                ledger = SchedulerUsagePolicy.seeded(from: file.history, now: now)
                saveLedger()
            }
            if changed || trimmed.count != file.history.count { save() }
        } catch {
            // Quarantine the unreadable file; a later save must not destroy it.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("scheduler.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            tasks = []
            history = []
            persistenceError = "Could not read scheduler.json: \(error.localizedDescription). Saved as \(backup.lastPathComponent)."
        }
    }

    /// Load the durable budget counter. Returns `true` when the file does not
    /// exist yet and the caller must seed it from history.
    ///
    /// An unreadable, newer-schema or impossible counter fails **closed**:
    /// every task with a `dailyTokenLimit` stops until the user restores or
    /// removes `scheduler-usage.json`. Seeding it from the trimmed history
    /// would reopen CORE-01 from the other side — a corrupt file would become a
    /// budget refund.
    private func loadLedger(now: Date) -> Bool {
        usageBudgetFailClosed = false
        usageReadOnly = false
        usageWriteFailed = false
        // `SecureFile.read` also returns nil for an existing but unreadable
        // file; that is not a fresh install. Only an absent file may be seeded.
        if FileManager.default.fileExists(atPath: usageURL.path) {
            guard let data = try? Data(contentsOf: usageURL) else {
                usageReadOnly = true
                usageBudgetFailClosed = true
                ledger = SchedulerUsageLedger()
                persistenceError = "Could not read scheduler-usage.json. Daily token limits stay paused until the file is readable or removed."
                return false
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["schemaVersion"] as? Int,
               version > PersistenceSchema.current {
                usageReadOnly = true
                usageBudgetFailClosed = true
                ledger = SchedulerUsageLedger()
                persistenceError = "scheduler-usage.json was written by a newer Melon Tools. Daily token limits stay paused until the app is updated."
                return false
            }
            if let decoded = try? JSONDecoder().decode(SchedulerUsageLedger.self, from: data),
               SchedulerUsagePolicy.isValid(decoded, now: now) {
                ledger = SchedulerUsagePolicy.pruned(decoded, now: now)
                return false
            }
            // Keep the original file (and a timestamped copy) for recovery;
            // never replace it with a zeroed counter, and never rewrite it
            // while the counter is untrusted.
            let backup = usageURL.deletingLastPathComponent()
                .appendingPathComponent("scheduler-usage.corrupt-\(Int(now.timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: usageURL, to: backup)
            usageReadOnly = true
            usageBudgetFailClosed = true
            ledger = SchedulerUsageLedger()
            persistenceError = "Could not read scheduler-usage.json (copy: \(backup.lastPathComponent)). Daily token limits stay paused until the file is restored or removed."
            return false
        }
        ledger = SchedulerUsageLedger()
        return true
    }

    /// Snapshot and hand encoding plus the atomic write to the serial writer.
    /// The main actor is never blocked by the history-sized payload.
    private func save() {
        guard !readOnly, !backupRestoreSuspended else { return }
        let file = SchedulerFile(tasks: tasks, history: history)
        let url = fileURL
        persistence.submit(url: url) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(file)
        }
    }

    /// The counter is tiny (a few kilobytes) and is the only durable record of
    /// paid spend. It is written synchronously and atomically: returning from a
    /// finished run before its usage is on disk would let a crash or a failed
    /// background write refund the budget (CORE-01).
    private func saveLedger() {
        guard !readOnly, !backupRestoreSuspended, !usageReadOnly else { return }
        let snapshot = SchedulerUsagePolicy.pruned(ledger, now: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = usageURL
        let write = usageWrite
        do {
            try write(try encoder.encode(snapshot), url)
            ledger = snapshot
            usageWriteFailed = false
            usageBudgetFailClosed = false
        } catch {
            // Keep the in-memory spend and fail closed until a later write
            // succeeds. The file on disk is the previous atomic snapshot, never
            // a partially written one.
            usageWriteFailed = true
            usageBudgetFailClosed = true
            persistenceError = "Could not save scheduler-usage.json: \(error.localizedDescription). Daily token limits are paused until the counter can be written."
        }
    }

    /// Wait for every queued write. Tests use it before reading the files;
    /// app termination uses it so the last run is not lost on quit.
    func flushSave() {
        persistence.flush()
    }

    /// Async seam for backup export/import: waits until every queued snapshot
    /// is on disk without blocking the main actor. Called before reading the
    /// files for a backup and before a restore replaces them, so a pending
    /// snapshot cannot overwrite the restored state.
    func flushPendingWrites() async {
        let writer = persistence
        await Task.detached(priority: .utility) {
            writer.flush()
        }.value
    }

    /// Scoped suspension for a backup restore. A restore replaces the files
    /// while crypto runs off the main actor; without the scope a run that
    /// finishes, a tick or a CRUD edit would rewrite the pre-restore snapshot
    /// over the restored one (or interleave with the atomic replace).
    ///
    /// Refuses while a run is in flight: suppressing that run's completion
    /// would lose a billed result and its history entry, and reloading the
    /// restored file afterwards would discard it. The caller shows the error
    /// and retries once the scheduler is idle.
    ///
    /// After `await`, every earlier write is on disk and nothing new is
    /// accepted until `endBackupRestore`.
    func beginBackupRestore() async throws {
        guard activeRun == nil, runningTaskID == nil else {
            throw SchedulerRestoreError.runInProgress
        }
        queuedTaskIDs.removeAll()
        backupRestoreSuspended = true
        await flushPendingWrites()
    }

    /// Leave the suspension. `restored == true` reloads the files that were
    /// just put in place, so the in-memory tasks/history/ledger match them and
    /// the next save cannot resurrect the old state. `restored == false` (a
    /// failed restore) only resumes: nothing was replaced and nothing is
    /// reloaded.
    func endBackupRestore(restored: Bool) {
        backupRestoreSuspended = false
        persistence.discardPending()
        if restored { load() }
    }

    /// Whether a backup restore currently owns the files (diagnostics/tests).
    var isSuspendedForBackupRestore: Bool { backupRestoreSuspended }

    // MARK: - CRUD

    @discardableResult
    func addTask(
        name: String,
        prompt: String,
        model: String,
        reasoningEffort: String?,
        intervalMinutes: Int,
        enabled: Bool,
        workingDirectory: String? = nil,
        includeGitContext: Bool = false,
        maxTokens: Int? = nil,
        dailyTokenLimit: Int? = nil,
        retryLimit: Int = 0,
        retryDelayMinutes: Int = 5,
        scheduleKind: SchedulerScheduleKind = .interval,
        cronExpression: String? = nil,
        timeZoneIdentifier: String? = nil,
        now: Date = Date()
    ) -> SchedulerTask {
        let interval = clampedInterval(intervalMinutes)
        var task = SchedulerTask(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt,
            model: model,
            reasoningEffort: reasoningEffort,
            workingDirectory: normalizedDirectory(workingDirectory),
            includeGitContext: includeGitContext,
            maxTokens: maxTokens,
            dailyTokenLimit: dailyTokenLimit,
            retryLimit: retryLimit,
            retryDelayMinutes: retryDelayMinutes,
            intervalMinutes: interval,
            scheduleKind: scheduleKind,
            cronExpression: scheduleKind == .cron ? normalizedCron(cronExpression) : nil,
            timeZoneIdentifier: normalizedTimeZone(timeZoneIdentifier),
            enabled: enabled,
            createdAt: now.timeIntervalSince1970
        )
        // An invalid schedule is never persisted; the editor blocks Save and
        // shows the same message first.
        guard task.validationError == nil else { return task }
        task.nextRunAt = enabled
            ? SchedulerPolicy.nextRun(after: now, task: task)?.timeIntervalSince1970
            : nil
        tasks.append(task)
        save()
        return task
    }

    func updateTask(
        id: String,
        name: String,
        prompt: String,
        model: String,
        reasoningEffort: String?,
        intervalMinutes: Int,
        enabled: Bool,
        workingDirectory: String? = nil,
        includeGitContext: Bool = false,
        maxTokens: Int? = nil,
        dailyTokenLimit: Int? = nil,
        retryLimit: Int = 0,
        retryDelayMinutes: Int = 5,
        scheduleKind: SchedulerScheduleKind = .interval,
        cronExpression: String? = nil,
        timeZoneIdentifier: String? = nil,
        now: Date = Date()
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var task = tasks[index]
        let interval = clampedInterval(intervalMinutes)
        task.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        task.prompt = prompt
        task.model = model
        task.reasoningEffort = reasoningEffort
        task.workingDirectory = normalizedDirectory(workingDirectory)
        task.includeGitContext = includeGitContext
        task.maxTokens = maxTokens
        task.dailyTokenLimit = dailyTokenLimit
        task.retryLimit = retryLimit
        task.retryDelayMinutes = retryDelayMinutes
        task.intervalMinutes = interval
        task.scheduleKind = scheduleKind
        task.cronExpression = scheduleKind == .cron ? normalizedCron(cronExpression) : nil
        task.timeZoneIdentifier = normalizedTimeZone(timeZoneIdentifier)
        guard task.validationError == nil else { return }
        task.enabled = enabled
        task.nextRunAt = enabled
            ? SchedulerPolicy.nextRun(after: now, task: task)?.timeIntervalSince1970
            : nil
        tasks[index] = task
        save()
    }

    func deleteTask(id: String) {
        guard runningTaskID != id else {
            persistenceError = L("Task is running; wait for it to finish before deleting.")
            return
        }
        tasks.removeAll { $0.id == id }
        history.removeAll { $0.taskId == id }
        queuedTaskIDs.removeAll { $0 == id }
        if ledger.days.removeValue(forKey: id) != nil { saveLedger() }
        save()
    }

    func setEnabled(_ enabled: Bool, id: String, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].enabled != enabled else { return }
        var task = tasks[index]
        task.enabled = enabled
        task.nextRunAt = enabled
            ? SchedulerPolicy.nextRun(after: now, task: task)?.timeIntervalSince1970
            : nil
        tasks[index] = task
        save()
    }

    // MARK: - Running

    /// One tick: at most one due task is executed. A tick never starts while a
    /// run is active or a manual queue is waiting; the queue drains after the
    /// active run. Overdue tasks are never replayed — each run moves its own
    /// `nextRunAt` one interval forward.
    func tick(now: Date = Date()) async {
        guard !backupRestoreSuspended else { return }
        guard activeRun == nil, queuedTaskIDs.isEmpty, runningTaskID == nil else { return }
        guard gatewayIsRunning else { return }
        guard let task = SchedulerPolicy.due(tasks, now: now, excluding: runningTaskID).first else {
            return
        }
        // Do not burn a scheduled run while the account pool is paused or the
        // quota is below the reserve. Provider-namespaced models route outside
        // the Codex pool and remain eligible.
        guard poolGuard?(task) ?? Self.poolAllows(task) else { return }
        let completed = await performRun(taskID: task.id)
        if completed { await drainQueue() }
    }

    /// Idle: runs the task and awaits completion, so tests and callers observe
    /// the result. Busy: appends to the manual queue (deduplicated) and returns
    /// at once so the UI can show it. Run now always runs, even for a disabled
    /// task, and advances the schedule so the next scheduled run is a full
    /// interval away.
    func runNow(id: String) async {
        guard !backupRestoreSuspended else { return }
        guard tasks.contains(where: { $0.id == id }) else { return }
        guard activeRun == nil, runningTaskID == nil else {
            enqueue(id)
            return
        }
        let completed = await performRun(taskID: id)
        if completed { await drainQueue() }
    }

    /// Stop the active run and drop every queued manual run. The cancelled run
    /// records `.cancelled`, is never retried and does not drain the queue.
    func cancelCurrent() {
        queuedTaskIDs.removeAll()
        guard activeRun != nil else {
            isCancelling = false
            return
        }
        isCancelling = true
        activeRun?.cancel()
        runner.cancel()
    }

    /// Start one run under a cancellable Task handle and wait for it. `false`
    /// means the run was cancelled and the queue must not continue.
    private func performRun(taskID: String) async -> Bool {
        let run = Task { @MainActor in
            await self.execute(taskID: taskID)
        }
        activeRun = run
        let completed = await run.value
        activeRun = nil
        isCancelling = false
        return completed
    }

    /// Drain manual requests one at a time. Deleted tasks are skipped and a
    /// cancelled run stops the drain.
    private func drainQueue() async {
        while activeRun == nil, let next = nextQueuedTaskID() {
            let completed = await performRun(taskID: next)
            if !completed { return }
        }
    }

    private func nextQueuedTaskID() -> String? {
        while !queuedTaskIDs.isEmpty {
            let id = queuedTaskIDs.removeFirst()
            if tasks.contains(where: { $0.id == id }) { return id }
        }
        return nil
    }

    private func enqueue(_ id: String) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        guard !queuedTaskIDs.contains(id) else { return }
        queuedTaskIDs.append(id)
    }

    /// User-facing reason recorded when the durable counter cannot be read.
    static let unreadableLedgerMessage = String(
        format: L("Daily token counter is unreadable (%@). Paid runs with a limit are paused until the file is restored or removed."),
        "scheduler-usage.json"
    )

    /// Message recorded in a blocked run. A write failure is not the same as a
    /// corrupt counter: the UI must tell the user what to fix.
    private var budgetBlockedMessage: String {
        usageWriteFailed
            ? "Daily token counter could not be saved. Paid runs with a limit are paused until the counter can be written."
            : Self.unreadableLedgerMessage
    }

    /// Records a blocked run for an untrusted counter. Returns `nil` when the
    /// task disappeared, so the caller can fall through safely.
    private func blockForUnreadableLedger(
        task running: SchedulerTask,
        index: Int,
        started: Date
    ) -> Bool? {
        guard tasks.indices.contains(index), tasks[index].id == running.id else { return nil }
        var blocked = running
        blocked.lastRunAt = started.timeIntervalSince1970
        blocked.lastStatus = .error
        blocked.lastError = budgetBlockedMessage
        blocked.lastResult = ""
        blocked.lastDurationMs = 0
        blocked.lastTokens = nil
        blocked.nextRunAt = blocked.enabled
            ? SchedulerPolicy.nextRun(after: started, task: blocked)?.timeIntervalSince1970
            : nil
        tasks[index] = blocked
        let entry = SchedulerHistoryEntry(
            taskId: running.id,
            at: started.timeIntervalSince1970,
            status: .error,
            model: blocked.model,
            durationMs: 0,
            tokens: nil,
            result: "",
            error: budgetBlockedMessage
        )
        history = SchedulerPolicy.trimHistory([entry] + history)
        save()
        return true
    }

    /// One run. `true` when it finished normally (including a daily-budget
    /// skip), `false` when it was cancelled.
    private func execute(taskID: String) async -> Bool {
        guard !backupRestoreSuspended else { return true }
        guard runningTaskID == nil else { return true }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return true }

        let started = Date()
        var running = tasks[index]
        running.lastStatus = .running
        running.lastError = nil
        tasks[index] = running
        runningTaskID = taskID
        defer { runningTaskID = nil }

        // A previous counter write failed. Retry before blocking: if the disk
        // is writable again, this run may proceed against a durable budget.
        if usageWriteFailed { saveLedger() }
        // Daily token budget: checked before every request, manual or
        // scheduled. The durable ledger is the counter — history is trimmed
        // and cannot be trusted for spend. An untrusted counter fails closed:
        // a limited task stops instead of spending against a zeroed budget.
        if usageBudgetFailClosed, running.dailyTokenLimit != nil,
           let blockedEntry = blockForUnreadableLedger(task: running, index: index, started: started) {
            return blockedEntry
        }
        if let usage = SchedulerPolicy.dailyTokenUsage(
            task: running,
            ledger: ledger,
            now: started
        ), usage.isReached {
            var blocked = running
            blocked.lastRunAt = started.timeIntervalSince1970
            blocked.lastStatus = .error
            blocked.lastError = usage.message
            blocked.lastResult = ""
            blocked.lastDurationMs = 0
            blocked.lastTokens = nil
            blocked.nextRunAt = blocked.enabled
                ? SchedulerPolicy.nextRun(after: started, task: blocked)?.timeIntervalSince1970
                : nil
            tasks[index] = blocked
            let entry = SchedulerHistoryEntry(
                taskId: taskID,
                at: started.timeIntervalSince1970,
                status: .error,
                model: blocked.model,
                durationMs: 0,
                tokens: nil,
                result: "",
                error: usage.message
            )
            history = SchedulerPolicy.trimHistory([entry] + history)
            save()
            return true
        }

        let result = await runner.run(task: running, gateway: currentGateway)
        // The runner already maps a cancelled transport to `.cancelled`. Do
        // not re-check Task.isCancelled here: a cancel that lands after a
        // successful response but before this save must not discard the result.
        let cancelled = result.status == .cancelled
        let finishedAt = Date()
        // Billed tokens belong in the ledger even when the task was deleted
        // while the request was in flight: the provider already charged them.
        if !cancelled, let tokens = result.tokens, tokens > 0 {
            recordUsage(tokens, taskID: taskID, at: finishedAt)
        }

        // The task may have been deleted while the request was in flight.
        guard let currentIndex = tasks.firstIndex(where: { $0.id == taskID }) else {
            return true
        }
        var updated = tasks[currentIndex]
        let body = SchedulerPolicy.truncatedResult(result.result)
        updated.lastRunAt = finishedAt.timeIntervalSince1970
        updated.lastStatus = cancelled ? .cancelled : result.status
        updated.lastResult = cancelled ? "" : body
        updated.lastError = cancelled
            ? SchedulerRunner.cancelledMessage
            : result.error.map { SchedulerPolicy.truncatedResult($0) }
        updated.lastDurationMs = result.durationMs
        updated.lastTokens = cancelled ? nil : result.tokens

        if cancelled {
            // User intent: normal schedule, no retry, no failure history.
            updated.nextRunAt = updated.enabled
                ? SchedulerPolicy.nextRun(after: finishedAt, task: updated)?.timeIntervalSince1970
                : nil
        } else if result.status == .error, updated.enabled, updated.retryAttempt < updated.retryLimit {
            updated.retryAttempt += 1
            updated.nextRunAt = finishedAt
                .addingTimeInterval(TimeInterval(updated.retryDelayMinutes * 60))
                .timeIntervalSince1970
            let suffix = "retry \(updated.retryAttempt)/\(updated.retryLimit)"
            updated.lastError = ((result.error ?? L("Task failed")) + " · " + suffix)
        } else {
            if result.status == .ok { updated.retryAttempt = 0 }
            // Failures keep the task enabled; the next attempt is one interval
            // away or the next cron fire (no burst).
            updated.nextRunAt = updated.enabled
                ? SchedulerPolicy.nextRun(after: finishedAt, task: updated)?.timeIntervalSince1970
                : nil
        }
        tasks[currentIndex] = updated

        let entry = SchedulerHistoryEntry(
            taskId: taskID,
            at: finishedAt.timeIntervalSince1970,
            status: updated.lastStatus,
            model: updated.model,
            durationMs: result.durationMs,
            tokens: cancelled ? nil : result.tokens,
            result: cancelled ? "" : body,
            error: cancelled
                ? SchedulerRunner.cancelledMessage
                : result.error.map { SchedulerPolicy.truncatedResult($0) }
        )
        history = SchedulerPolicy.trimHistory([entry] + history)
        save()

        if !cancelled,
           notifications.isEnabled(),
           let notice = SchedulerNotificationPolicy.notice(
               taskId: taskID,
               taskName: updated.name,
               status: result.status,
               result: body,
               error: result.error,
               now: finishedAt
           ) {
            notifications.post(notice)
        }
        return !cancelled
    }

    // MARK: - Model list

    /// `GET /v1/models` with the Bearer key. The exact id is kept for storage;
    /// the picker groups it by prefix.
    func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelsError = nil
        defer { isLoadingModels = false }
        do {
            let ids = try await catalog.fetchModels(gateway: currentGateway)
            models = ids
            if ids.isEmpty {
                modelsError = L("The service returned an empty model list.")
            }
        } catch {
            modelsError = String(describing: error)
        }
    }

    func loadModelsIfNeeded() async {
        guard models.isEmpty else { return }
        await loadModels()
    }

    // MARK: - Helpers

    func history(for taskID: String) -> [SchedulerHistoryEntry] {
        history.filter { $0.taskId == taskID }
    }

    /// Durable per-day spend per task. Exposed for diagnostics and tests; the
    /// UI reads `history`, which is bounded.
    var usageLedger: SchedulerUsageLedger { ledger }

    /// Add a billed run to the durable counter and persist it. Never derived
    /// from the trimmed history.
    private func recordUsage(_ tokens: Int, taskID: String, at date: Date) {
        SchedulerUsagePolicy.record(tokens, taskID: taskID, now: date, in: &ledger)
        saveLedger()
    }

    private func clampedInterval(_ value: Int) -> Int {
        max(1, min(value, SchedulerLimits.maximumIntervalMinutes))
    }

    private func normalizedCron(_ expression: String?) -> String? {
        guard let expression else { return nil }
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedTimeZone(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }
}
