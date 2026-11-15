import Foundation
import Combine
import CryptoKit
import os

/// Manages the local inference engine (`llama-server`) process lifecycle, port allocation,
/// health verification, and gateway integration on macOS.
///
/// Lifecycle rules that the previous version did not enforce:
/// * every launch/stop is owned by a generation number, so a Start that was
///   overtaken by Stop (or by another Start) can never stop the *new* process;
/// * `MainActor` does not make an `async` function atomic — each `await` is a
///   suspension point where the world may change, so the generation is
///   re-checked after every one of them;
/// * "router is up" and "this model is loaded" are separate facts. The engine
///   answers `/health` while every model is still `unloaded`, so a launch is
///   only successful once the router reports the requested model as `loaded`.
@MainActor
final class LocalInferenceService: ObservableObject {
    static let shared = LocalInferenceService()

    private static let logger = Logger(subsystem: "dev.melontools.app", category: "LocalInference")

    enum ServiceStatus: Equatable {
        case stopped
        case starting(modelId: String)
        case running(port: Int, modelId: String)
        case stopping
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        /// True from the moment `loadModel` starts until the model is loaded, so
        /// the UI can show progress instead of a dead Start button.
        var isStarting: Bool {
            if case .starting = self { return true }
            return false
        }

        var isStopping: Bool { self == .stopping }

        var startingModelId: String? {
            if case .starting(let id) = self { return id }
            return nil
        }
    }

    /// State of one model inside the router, as reported by `GET /models`.
    enum RouterModelStatus: String, Equatable {
        case unloaded
        case loading
        case loaded
        case sleeping
        case failed
    }

    /// Live figures pulled from the engine's Prometheus endpoint (§21).
    struct InferenceMetrics: Equatable {
        var promptTokens: Int = 0
        var predictedTokens: Int = 0
        var promptPerSecond: Double = 0
        var predictedPerSecond: Double = 0
        var updatedAt: Date = .distantPast
    }

    /// The engine actually in use, with provenance taken from *that* file.
    ///
    /// The previous code took the executable from a custom path but reported the
    /// version and digest of an unrelated runtime manifest, so an external
    /// binary looked bundled and verified.
    struct ResolvedRuntime {
        enum Provenance: Equatable {
            case customBinary
            case packaged(RuntimeManifest)
            case system
        }

        var binaryURL: URL
        var provenance: Provenance
        var version: String?
        var build: String?
        var digestStatus: String

        var isBundled: Bool {
            if case .packaged(let manifest) = provenance { return manifest.isBundled }
            return false
        }
    }

    @Published private(set) var status: ServiceStatus = .stopped
    @Published private(set) var metrics: InferenceMetrics?
    /// Reason the last metrics poll failed, so the UI can say "unavailable"
    /// instead of silently showing zeroes.
    @Published private(set) var metricsError: String?
    @Published private(set) var failedModelId: String?
    @Published private(set) var currentModel: LocalModel?
    @Published private(set) var port: Int = 18318
    @Published private(set) var internalToken: String = UUID().uuidString

    /// Port the gateway must advertise for local models: the prompt relay when
    /// it is running, the router itself otherwise. The relay is what applies
    /// each model's system prompt to every request.
    var publishedPort: Int {
        let relay = SystemPromptProxy.shared.port
        return relay > 0 ? Int(relay) : port
    }
    @Published private(set) var logLines: [String] = []
    /// Bumped on every engine-log flush. `logLines` is a ring buffer, so once it
    /// is full its count no longer changes and cannot signal new output; the
    /// Console pane follows the tail on this value instead.
    @Published private(set) var logRevision = 0
    /// PID of the running engine, for diagnostics and for the crash check.
    @Published private(set) var processIdentifier: Int32?
    /// Model states as the router itself reports them.
    @Published private(set) var routerStates: [String: RouterModelStatus] = [:]
    /// Last error from an explicit engine restart (settings change, crash).
    @Published private(set) var engineError: String?
    /// Set when the gateway did not confirm the local routes in `/v1/models`.
    /// Kept separate from `engineError`: the engine can be healthy while the
    /// gateway never picked the routes up.
    @Published private(set) var publicationError: String?
    private var gatewayObservation: AnyCancellable?
    private var publicationTask: Task<Void, Never>?
    @Published var customBinaryPath: String? = UserDefaults.standard.string(forKey: "melon_custom_llama_server_path") {
        didSet {
            // Tests point at a throwaway binary; persisting that path would
            // outlive the run and overwrite the user's choice. The test host is
            // a separate process, so in-memory state is enough.
            if !AppRuntime.isTesting {
                UserDefaults.standard.set(customBinaryPath, forKey: "melon_custom_llama_server_path")
            }
            objectWillChange.send()
        }
    }

    func clearLogs() {
        logSink.clear()
        logLines = []
        logRevision &+= 1
    }

    private var process: Process?
    private var processGeneration: Int = 0
    private var generation: Int = 0
    private var startTask: Task<Void, Error>?
    private var monitorTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    /// Last raw counter sample; live rates are the delta against it.
    private var metricsBaseline: InferenceMetrics?
    private var logFlushTask: Task<Void, Never>?
    private let logSink = EngineLogSink()
    private var appliedPresetDigest: String?

    private init() {
        logSink.onFlush = { [weak self] lines in
            Task { @MainActor in
                self?.logLines = lines
                self?.logRevision &+= 1
            }
        }
        logLines = logSink.snapshot()
        appliedPresetDigest = Self.readAppliedPresetDigest()
        // Constructing `CodexGatewayService.shared` reads/writes the user's
        // gateway key and port. Tests drive publication through explicit hooks
        // instead, so they must not create that singleton at all.
        if !AppRuntime.isTesting {
            gatewayObservation = CodexGatewayService.shared.$status
                .removeDuplicates()
                .sink { [weak self] status in
                    guard case .running = status else { return }
                    Task { @MainActor in self?.publishLocalRoutesIfNeeded() }
                }
        }
    }

    /// Clears the banner after the user acknowledged it.
    func clearVisibleError() {
        publicationError = nil
        engineError = nil
    }

    // MARK: - Gateway publication

    /// Test seam for the publication loop.
    ///
    /// Production always uses `.live`. Tests replace the hooks to run the real
    /// retry/verification/cancellation code against an isolated fixture instead
    /// of a live gateway.
    struct PublicationHooks {
        var writeConfig: @MainActor () throws -> Void
        var refreshCatalog: @MainActor () throws -> Void
        var gatewayIsRunning: @MainActor () -> Bool
        var servedModelIDs: @MainActor () async throws -> Set<String>
        var readyAliases: @MainActor () -> [String]
        /// Sleep between retries; tests replace it with a no-op.
        var wait: @MainActor (UInt64) async -> Void = {
            try? await Task.sleep(nanoseconds: $0)
        }

        @MainActor static let live = PublicationHooks(
            writeConfig: {
                try CodexGatewayService.shared.flushConfigWrite(
                    reason: "local ai routes",
                    force: true
                )
            },
            refreshCatalog: {
                _ = try CodexModelCatalog.sync(
                    sources: ModelSourcesStore.shared.effectiveSources,
                    updateConfig: CodexGatewayService.shared.codexRoute == .melon,
                    selectedPoolSlugs: ModelSourcesStore.currentPoolUnion()
                )
            },
            gatewayIsRunning: {
                CodexGatewayService.shared.isRunning
            },
            servedModelIDs: {
                try await LocalInferenceService.fetchGatewayModelIDs()
            },
            readyAliases: {
                LocalInferenceService.readyAliases(in: LocalModelStore.shared.models)
            }
        )
    }

#if DEBUG
    var publicationHooks = PublicationHooks.live
#else
    private let publicationHooks = PublicationHooks.live
#endif

    /// Writes the generated routes and proves the gateway actually serves them.
    ///
    /// Writing `config.yaml` is not publication: the engine starts answering
    /// HTTP before its config watcher is ready, so a write that lands too early
    /// can be silently lost. Retry with a fresh atomic write until `/v1/models`
    /// lists every ready local alias.
    func publishLocalRoutes(verify: Bool = true, expectingAbsent: [String] = []) {
        publicationTask?.cancel()
        publicationTask = Task { [weak self] in
            await self?.performPublication(verify: verify, expectingAbsent: expectingAbsent)
        }
    }

    func publishLocalRoutesIfNeeded() {
        guard LocalModelStore.shared.models.contains(where: { $0.runtimeStatus == .ready }) else {
            publicationError = nil
            return
        }
        publishLocalRoutes()
    }

#if DEBUG
    /// Lets a test await the publication it triggered.
    func waitForPublication() async {
        await publicationTask?.value
    }

    /// Cancels the queued task without replacing its hooks, so a test can
    /// prove that a task cancelled before its first suspension cannot write.
    func cancelPendingPublicationForTesting() {
        publicationTask?.cancel()
    }

    func resetPublicationForTesting() {
        publicationTask?.cancel()
        publicationTask = nil
        publicationError = nil
        publicationHooks = .live
    }
    /// Stops publication from touching the real gateway during test teardown,
    /// where the engine is stopped after the assertions have finished.
    func suspendPublicationForTesting() {
        publicationTask?.cancel()
        publicationTask = nil
        publicationError = nil
        publicationHooks = PublicationHooks(
            writeConfig: {},
            refreshCatalog: {},
            gatewayIsRunning: { false },
            servedModelIDs: { [] },
            readyAliases: { [] }
        )
    }
#endif

    /// Every alias that is currently served by a ready model.
    nonisolated static func readyAliases(in models: [LocalModel]) -> [String] {
        models
            .filter { $0.runtimeStatus == .ready }
            .map { $0.id.hasPrefix("local/") ? $0.id : "local/\($0.id)" }
    }

    private func performPublication(verify: Bool, expectingAbsent: [String]) async {
        // The task may have been cancelled by a newer publication before the
        // main actor ever ran it. Capturing hooks/writing first would let that
        // stale task publish through hooks that teardown has already restored.
        guard !Task.isCancelled else { return }
        let hooks = publicationHooks

        do {
            try hooks.writeConfig()
        } catch {
            finishPublication(
                String(format: L("Local AI routes were not written: %@"), error.localizedDescription)
            )
            return
        }

        // Catalog and config failures are independent facts. A later successful
        // verification must never clear a catalog error that the user has to fix.
        do {
            try hooks.refreshCatalog()
        } catch {
            finishPublication(
                String(format: L("Local AI model catalog was not updated: %@"), error.localizedDescription)
            )
            return
        }

        guard verify else {
            finishPublication(nil)
            return
        }
        guard hooks.gatewayIsRunning() else {
            // Nothing is serving the stale routes; a later gateway start will
            // publish the current list from `writeConfig()`.
            finishPublication(nil)
            return
        }

        let ready = hooks.readyAliases()
        let expected = expectingAbsent.isEmpty ? ready : expectingAbsent
        guard !expected.isEmpty else {
            finishPublication(nil)
            return
        }

        // Startup race: the HTTP endpoint answers before the watcher is ready.
        // Each retry writes the config again, and the later attempts land after
        // the watcher exists. Present needs the full ~15 s budget; removal
        // after Stop/delete is checked on a shorter budget.
        let waits: [UInt64] = expectingAbsent.isEmpty
            ? [0, 500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000]
            : [0, 300_000_000, 700_000_000, 1_000_000_000, 1_500_000_000]

        var unresolved = expected
        for (index, wait) in waits.enumerated() {
            if Task.isCancelled { return }
            if wait > 0 { await hooks.wait(wait) }
            if Task.isCancelled { return }
            if index > 0 {
                // A fresh write also covers a watcher that missed the first event.
                do {
                    try hooks.writeConfig()
                } catch {
                    // Never let a swallowed rewrite failure fall through to a
                    // matching catalogue: that would clear a real error.
                    finishPublication(
                        String(
                            format: L("Local AI gateway config could not be rewritten: %@"),
                            error.localizedDescription
                        )
                    )
                    return
                }
            }
            guard let served = try? await hooks.servedModelIDs() else { continue }
            // The task may have been cancelled while the HTTP request was in
            // flight; a late answer belongs to the previous lifecycle.
            if Task.isCancelled { return }
            unresolved = expectingAbsent.isEmpty
                ? ready.filter { !served.contains($0) }
                : expectingAbsent.filter { served.contains($0) }
            if unresolved.isEmpty {
                finishPublication(nil)
                return
            }
        }

        if Task.isCancelled { return }
        if expectingAbsent.isEmpty {
            let message = String(
                format: L("Local AI models are missing from the gateway API: %@"),
                unresolved.sorted().joined(separator: ", ")
            )
            publicationError = message
            CodexGatewayService.shared.auditLog("local AI publication unverified: \(unresolved.sorted().joined(separator: ", "))")
        } else {
            let message = String(
                format: L("Local AI models are still served after stop: %@"),
                unresolved.sorted().joined(separator: ", ")
            )
            publicationError = message
            CodexGatewayService.shared.auditLog("local AI routes still served after stop: \(unresolved.sorted().joined(separator: ", "))")
        }
    }

    /// Assigns the publication result unless a newer publication already
    /// cancelled this one while it was suspended.
    private func finishPublication(_ error: String?) {
        guard !Task.isCancelled else { return }
        publicationError = error
    }

    /// `/v1/models` as served by the running gateway.
    private static func fetchGatewayModelIDs() async throws -> Set<String> {
        let gateway = CodexGatewayService.shared
        guard let base = URL(string: gateway.baseURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/models"))
        request.timeoutInterval = 3
        request.setValue("Bearer \(gateway.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await NetworkProxy.directSession().data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Payload: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        return Set(try JSONDecoder().decode(Payload.self, from: data).data.map(\.id))
    }

    // MARK: - Binary Discovery

    /// The engine selected right now, with the metadata of *that* file.
    var resolvedRuntime: ResolvedRuntime? {
        if let custom = customBinaryPath, !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return ResolvedRuntime(
                binaryURL: URL(fileURLWithPath: custom),
                provenance: .customBinary,
                version: nil,
                build: nil,
                digestStatus: L("Unverified (external binary)")
            )
        }
        if let active = RuntimeStore.shared.active,
           let binary = RuntimeStore.shared.activeBinaryURL {
            let manifest = RuntimeStore.shared.active
            return ResolvedRuntime(
                binaryURL: binary,
                provenance: .packaged(active),
                version: manifest?.version,
                build: manifest?.build,
                digestStatus: manifest.map { L(RuntimeStore.shared.integrity(of: $0)) } ?? L("Unverified")
            )
        }
        for candidate in ["/usr/local/bin/llama-server", "/opt/homebrew/bin/llama-server"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return ResolvedRuntime(
                    binaryURL: URL(fileURLWithPath: candidate),
                    provenance: .system,
                    version: nil,
                    build: nil,
                    digestStatus: L("Unverified (system binary)")
                )
            }
        }
        return nil
    }

    var binaryURL: URL? { resolvedRuntime?.binaryURL }

    /// True when the engine in use came from the bundle.
    var isUsingBundledRuntime: Bool { resolvedRuntime?.isBundled ?? false }

    /// Version recorded in the manifest. The engine is never executed just to
    /// fill a label: starting downloaded code needs an explicit Start.
    var runtimeVersion: String? { resolvedRuntime?.version }

    /// Digest status of the binary that will actually run.
    var runtimeChecksumStatus: String { resolvedRuntime?.digestStatus ?? L("Not found") }

    /// Build tag of the runtime in use, e.g. `b12099`.
    var runtimeBuild: String? { resolvedRuntime?.build }

    var isBinaryAvailable: Bool { binaryURL != nil }

    // MARK: - Port Allocation

    /// `nil` when the whole range is busy. Returning `start` anyway used to
    /// hand a taken port to the router, which then failed with a generic
    /// "engine did not start" after 60 s.
    private func findAvailablePort(startingFrom start: Int = 18318) -> Int? {
        for candidate in start...(start + 30) {
            var addr = sockaddr_in()
            addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(candidate).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { continue }

            // No SO_REUSEADDR here: on macOS it lets a second bind succeed on a
            // port that is already listening, so the probe would report a busy
            // port as free and the router would fail with "address in use".
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            close(sock)

            if bindResult == 0 {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Public lifecycle

    /// Starts the engine and loads exactly this model.
    func loadModel(_ model: LocalModel) async throws {
        let generation = beginOperation()
        startTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.startEngine(model: model, generation: generation)
        }
        startTask = task
        defer {
            if startTask == task { startTask = nil }
        }

        do {
            try await task.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if generation == self.generation {
                LocalModelStore.shared.updateModelStatus(id: model.id, status: .error)
            }
            throw error
        }
    }

    /// Stops the engine and every pending launch.
    func stop() async {
        let previouslyPublished = Self.readyAliases(in: LocalModelStore.shared.models)
        // The process belongs to the generation that started it; `generation`
        // is bumped first so a concurrent Start owns everything after this.
        let ownedProcessGeneration = processGeneration
        generation += 1
        let stopGeneration = generation
        startTask?.cancel()
        startTask = nil
        stopMonitoring()
        stopMetricsPolling()

        if status.isRunning || status.isStarting {
            status = .stopping
        }
        await terminateProcess(expectedGeneration: ownedProcessGeneration)
        // A newer Start may have taken ownership while the old engine was
        // shutting down; its state must not be overwritten by this Stop.
        guard generation == stopGeneration else { return }
        // The relay only exists to forward to this engine. Leaving it listening
        // kept the gateway's published port alive and answering 502 after Stop.
        SystemPromptProxy.shared.stop()
        SystemPromptProxy.shared.setUpstream(port: 0)
        currentModel = nil
        failedModelId = nil
        routerStates = [:]
        LocalModelStore.shared.normalizeRuntimeStates()
        status = .stopped
        publishLocalRoutes(expectingAbsent: previouslyPublished)
    }

    /// Synchronous shutdown for the app termination handler, where awaiting a
    /// task is not possible. Leaves no engine process behind (§11.3, NF-08).
    func stopSync() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        stopMonitoring()
        stopMetricsPolling()

        let hadProcess = process != nil
        let enginePID = process?.processIdentifier
        var forcedKill = false
        if let p = process, p.isRunning {
            let pid = p.processIdentifier
            // The whole group goes down: the router's model child is what keeps
            // the weights mapped, and letting the router exit first would orphan
            // it. `signalEngine` falls back to the pid when the group is absent.
            Self.signalEngine(pid: pid, signal: SIGTERM)
            // Quit runs on the main thread, so the grace period is bounded:
            // 10 × 50 ms, then SIGKILL and at most 4 × 50 ms more (~0.7 s).
            var exited = false
            for _ in 0..<10 {
                if !p.isRunning { exited = true; break }
                usleep(50_000)
            }
            if !exited {
                forcedKill = true
                Self.signalEngine(pid: pid, signal: SIGKILL)
                for _ in 0..<4 {
                    if !p.isRunning { break }
                    usleep(50_000)
                }
            }
        }
        // A model child that ignored SIGTERM outlives the router as its own
        // orphan or as the last member of the router's group. Reap only then:
        // a clean shutdown must stay cheap on the quit path. The reaper itself
        // is bounded to ~0.2 s (ps + one short grace), so the worst case stays
        // under one second even when SIGKILL was needed.
        let groupSurvived = enginePID.map { kill(-$0, 0) == 0 } ?? false
        if hadProcess, forcedKill || groupSurvived,
           let binary = RuntimeStore.shared.activeBinaryURL?.path, !binary.isEmpty {
            Self.reapOrphanedEnginesSync(binary: binary)
        }
        process = nil
        processIdentifier = nil
        processGeneration = 0
        SystemPromptProxy.shared.stop()
        SystemPromptProxy.shared.setUpstream(port: 0)
        closeLogSink()
        LocalModelStore.shared.normalizeRuntimeStates()
        currentModel = nil
        status = .stopped
    }

    /// Releases the weights of `model` before its files are unlinked.
    ///
    /// On macOS `unlink` does not free pages that are already mapped, so a
    /// running router keeps serving a deleted model and a re-import of the same
    /// path fails. Stopping the engine is the only reliable way to drop the
    /// mapping; the preset is rewritten on the next start.
    func releaseModelFiles(_ model: LocalModel) async {
        guard process != nil else { return }
        let servesModel = currentModel?.id == model.id || routerStates[model.id] == .loaded
        if servesModel || routerStates.isEmpty {
            await stop()
            return
        }
        do {
            try await unloadModelFromRouter(model.id)
        } catch {
            // The weights are still mapped. Deleting the file would not free
            // them and the router would keep answering a model the catalogue
            // no longer lists, so stop the engine instead.
            await stop()
        }
    }

    // MARK: - Generation helpers

    private func beginOperation() -> Int {
        generation += 1
        stopMonitoring()
        stopMetricsPolling()
        return generation
    }

    /// Re-checked after every `await`: another Start or a Stop may have taken
    /// ownership while this launch was suspended.
    private func ensureCurrent(_ operation: Int) throws {
        guard operation == generation else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func ensureProcessAlive() throws {
        guard let p = process, p.isRunning else {
            throw EngineFailure.engineExited(exitCode: process?.terminationStatus)
        }
    }

    // MARK: - Start

    private func startEngine(model: LocalModel, generation operation: Int) async throws {
        // Join an engine that already serves this exact model.
        if case .running(let existingPort, let id) = status, id == model.id,
           routerStates[model.id] == .loaded {
            if await checkHealth(port: existingPort, token: internalToken) {
                // `loadModel` bumps the generation, which stops both pollers.
                // Joining a live engine has to bring them back, otherwise a
                // second "Start" froze the cards for the rest of the run.
                startMetricsPolling(modelId: model.id)
                startMonitoring(generation: operation)
                return
            }
        }

        // Check before stopping: cancellation is cooperative, so a superseded
        // launch reached the stop first and killed the engine a newer launch
        // had just started. The second check keeps an await-race safe.
        try ensureCurrent(operation)
        await stopWithoutBumpingGeneration(operation: operation)
        try ensureCurrent(operation)

        guard let runtime = resolvedRuntime else {
            let message = L("llama-server runtime binary not found.")
            status = .failed(message)
            failedModelId = model.id
            engineError = message
            throw EngineFailure.binaryMissing
        }

        let modelFile = model.primaryFileURL(in: LocalModelStore.shared.modelsDirectory)
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            let message = String(format: L("Model file does not exist at %@"), modelFile.path)
            status = .failed(message)
            failedModelId = model.id
            LocalModelStore.shared.updateModelStatus(id: model.id, status: .notInstalled)
            throw EngineFailure.modelFileMissing(modelFile.path)
        }

        status = .starting(modelId: model.id)
        failedModelId = nil
        engineError = nil
        currentModel = model
        LocalModelStore.shared.updateModelStatus(id: model.id, status: .loading)

        guard let picked = findAvailablePort(startingFrom: 18318) else {
            let message = EngineFailure.portUnavailable.errorDescription
                ?? "No free local port."
            status = .failed(message)
            failedModelId = model.id
            engineError = message
            LocalModelStore.shared.updateModelStatus(id: model.id, status: .installed)
            throw EngineFailure.portUnavailable
        }
        port = picked
        internalToken = UUID().uuidString

        // The gateway is pointed at the prompt relay, which forwards to this
        // port. Started before any config write so the published URL is live.
        SystemPromptProxy.shared.setUpstream(port: UInt16(clamping: port))
        SystemPromptProxy.shared.start()

        let presetURL = try writeModelsPreset()
        var args = [
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--api-key", internalToken,
            "--models-preset", presetURL.path,
            "--models-max", "\(Self.modelsMaxConcurrent)",
            "--metrics",
            // Always send the validated value. Sending it only when > 1 left the
            // pinned runtime default (-1 = auto) in force, so the UI's "1" was a
            // promise the engine never received.
            "--parallel", "\(max(1, Self.parallelRequests))",
        ]
        let idle = Self.idleUnloadSeconds
        if idle > 0 {
            args += ["--sleep-idle-seconds", "\(idle)"]
        }

        let p = Process()
        p.executableURL = runtime.binaryURL
        p.arguments = args
        attachLogs(to: p, model: model)
        p.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                self?.handleProcessTermination(exitCode: code, generation: operation)
            }
        }

        do {
            try p.run()
            // Own process group: Stop and the crash reaper can then signal the
            // router and its model child with one negative-pid kill. Foundation
            // already creates the group on macOS, so EACCES here is expected;
            // only a genuinely missing group is worth a warning.
            let enginePID = p.processIdentifier
            let groupResult = setpgid(enginePID, enginePID)
            let groupErrno = errno
            if groupResult != 0, getpgid(enginePID) != enginePID {
                Self.logger.warning(
                    "engine process group unavailable pid=\(enginePID, privacy: .public) errno=\(groupErrno, privacy: .public)"
                )
            }
        } catch {
            // A launch that lost the generation must not overwrite the state
            // of the one that replaced it, nor close its log sink.
            if generation == operation {
                let message = String(format: L("Failed to start llama-server: %@"), error.localizedDescription)
                status = .failed(message)
                failedModelId = model.id
                engineError = message
                LocalModelStore.shared.updateModelStatus(id: model.id, status: .error)
                closeLogSink()
            }
            throw EngineFailure.spawnFailed(error.localizedDescription)
        }

        process = p
        processIdentifier = p.processIdentifier
        processGeneration = operation
        Self.logger.info("engine started pid=\(p.processIdentifier, privacy: .public) model=\(model.id, privacy: .public)")

        // Stop may have won the race while `run()` was starting the process.
        // Reap that orphan immediately instead of waiting for the health
        // timeout, and do not publish any state for a superseded launch.
        do {
            try ensureCurrent(operation)
        } catch {
            await terminateProcess(expectedGeneration: operation)
            throw error
        }

        // Health: the router process is up.
        do {
            try await waitForRouterHealth(generation: operation, timeoutSeconds: 60)
            try ensureCurrent(operation)
            // Model: the router actually loaded the requested weights.
            let actualContext = try await loadModelInRouter(model, generation: operation)
            try ensureCurrent(operation)
            // Publish the router's view immediately: waiting for the 5 s monitor
            // tick left `routerStates` empty right after a successful Start.
            if var states = await routerStatesSnapshot() {
                states[model.id] = .loaded
                routerStates = states
            } else {
                // The health check above already proved the router answers;
                // only the richer model list failed, so record what we know.
                routerStates[model.id] = .loaded
            }

            status = .running(port: port, modelId: model.id)
            failedModelId = nil
            appliedPresetDigest = presetDigest()
            Self.storeAppliedPresetDigest(presetDigest())
            recordAppliedContext(actualContext, for: model)
            LocalModelStore.shared.updateModelStatus(id: model.id, status: .ready)
            startMetricsPolling(modelId: model.id)
            startMonitoring(generation: operation)
            publishLocalRoutes()
        } catch {
            await stopWithoutBumpingGeneration(operation: operation)
            if generation == operation {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = .failed(message)
                failedModelId = model.id
                engineError = message
                LocalModelStore.shared.updateModelStatus(id: model.id, status: .error)
            }
            throw error
        }
    }

    /// Stop without invalidating the caller's generation. Used inside a launch
    /// that is already owned by a generation.
    private func stopWithoutBumpingGeneration(operation: Int? = nil) async {
        // A superseded launch must not touch the state of the launch that
        // replaced it. It still owns the process it spawned itself, though:
        // leaving that one running would leak an engine nobody can reach.
        if let operation, operation != generation {
            if processGeneration == operation {
                await terminateProcess(expectedGeneration: operation)
            }
            return
        }
        let previouslyPublished = Self.readyAliases(in: LocalModelStore.shared.models)
        let ownedProcessGeneration = processGeneration
        stopMetricsPolling()
        if status.isRunning || status.isStarting {
            status = .stopping
        }
        await terminateProcess(expectedGeneration: ownedProcessGeneration)
        if let operation, operation != generation { return }
        routerStates = [:]
        LocalModelStore.shared.normalizeRuntimeStates()
        currentModel = nil
        status = .stopped
        publishLocalRoutes(expectingAbsent: previouslyPublished)
    }

    /// Tears down the engine this call owns.
    ///
    /// `expectedGeneration` is the process generation captured before the call.
    /// If another launch has already replaced the process, no signal is sent:
    /// otherwise a stale Stop could kill the engine a newer Start just spawned.
    private func terminateProcess(expectedGeneration: Int? = nil) async {
        guard let p = process else { return }
        if let expectedGeneration, processGeneration != expectedGeneration { return }
        let pid = p.processIdentifier
        process = nil
        processIdentifier = nil
        processGeneration = 0
        var forcedKill = false
        if p.isRunning {
            // Negative pid signals the whole group; without it a router that
            // exits first would leave the model child holding the weights.
            Self.signalEngine(pid: pid, signal: SIGTERM)
            for _ in 0..<30 {
                if !p.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if p.isRunning {
                forcedKill = true
                Self.signalEngine(pid: pid, signal: SIGKILL)
                // A SIGKILLed router cannot stop the model process it spawned:
                // the child would keep the model mapped (gigabytes of RSS) and
                // the port busy until the next launch reaped it.
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        // A child that ignored SIGTERM can outlive a router that exited
        // cleanly as the last member of its group, so check the group too.
        let groupSurvived = kill(-pid, 0) == 0
        if forcedKill || groupSurvived,
           let binary = RuntimeStore.shared.activeBinaryURL?.path, !binary.isEmpty {
            await Self.reapOrphanedEngines(
                binary: binary, modelsPath: LocalPaths.models.path, appPID: getpid()
            )
        }
        // A newer launch may have attached its log sink while this one was
        // waiting for the old process to exit.
        if process == nil { closeLogSink() }
    }

    private func handleProcessTermination(exitCode: Int32, generation operation: Int) {
        // A stop we requested already cleaned up; only an unexpected exit needs
        // to normalise the registry and the gateway routes.
        guard operation == processGeneration, process != nil else { return }
        process = nil
        processIdentifier = nil
        processGeneration = 0
        stopMonitoring()
        stopMetricsPolling()
        closeLogSink()
        let previouslyPublished = Self.readyAliases(in: LocalModelStore.shared.models)
        routerStates = [:]
        LocalModelStore.shared.normalizeRuntimeStates()
        currentModel = nil
        let message = String(format: L("The engine exited unexpectedly (status %d)."), exitCode)
        status = .failed(message)
        engineError = message
        publishLocalRoutes(expectingAbsent: previouslyPublished)
        // A crash can leave the router's model child behind. Run the reaper
        // even if a Start wins the race and installs a new process: selection
        // excludes every router whose parent is this app, so only the old
        // orphan can be hit.
        if let binary = RuntimeStore.shared.activeBinaryURL?.path, !binary.isEmpty {
            let modelsPath = LocalPaths.models.path
            let appPID = getpid()
            Task.detached(priority: .utility) {
                await Self.reapOrphanedEngines(
                    binary: binary, modelsPath: modelsPath, appPID: appPID
                )
            }
        }
    }

    // MARK: - Router operations

    /// Health check of the router process itself.
    ///
    /// A `200` alone is not proof: any local listener can answer with an error
    /// body. The router reports success as `{"status":"ok"}`; newer builds also
    /// use `ready`. An unreadable or status-less body is therefore unhealthy.
    func checkHealth(port: Int, token: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        // Loopback GETs are cacheable by default and a cached answer made the
        // console and the status card disagree with the live engine.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, resp) = try await NetworkProxy.directSession().data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else { return false }
            return status == "ok" || status == "ready"
        } catch {
            return false
        }
    }

    private func waitForRouterHealth(generation operation: Int, timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try ensureCurrent(operation)
            try ensureProcessAlive()
            if await checkHealth(port: port, token: internalToken) { return }
            // `Task.sleep` throws on cancellation; swallowing it turned a
            // cancelled launch into a 60-second busy loop.
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw EngineFailure.healthTimeout
    }

    /// Asks the router to load the model and waits until it reports `loaded`.
    /// Returns the `n_ctx` the engine actually allocated, when reported.
    @discardableResult
    private func loadModelInRouter(_ model: LocalModel, generation operation: Int) async throws -> Int? {
        if let states = await routerStatesSnapshot(), states[model.id] == .loaded {
            return nil
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/models/load") else {
            throw EngineFailure.modelLoadFailed(model.id, "invalid endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(internalToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model.id])

        do {
            let (data, response) = try await NetworkProxy.directSession().data(for: request)
            let http = response as? HTTPURLResponse
            if let http, !(200...299).contains(http.statusCode) {
                throw EngineFailure.modelLoadFailed(model.id, Self.errorMessage(from: data, status: http.statusCode))
            }
        } catch let failure as EngineFailure {
            throw failure
        } catch {
            throw EngineFailure.modelLoadFailed(model.id, error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try ensureCurrent(operation)
            let statuses = await routerStatesSnapshot()
            switch statuses?[model.id] {
            case .loaded:
                return await routerContextLength(model.id)
            case .failed:
                throw EngineFailure.modelLoadFailed(model.id, L("The engine rejected this model."))
            default:
                break
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw EngineFailure.modelLoadTimeout(model.id)
    }

    private func unloadModelFromRouter(_ modelId: String) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/models/unload") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(internalToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": modelId])
        guard let (_, response) = try? await NetworkProxy.directSession().data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw EngineFailure.modelUnloadFailed(modelId)
        }
        // `/models/unload` returns success before the child stops, so a 2xx
        // alone does not prove the weights are gone.
        for _ in 0..<10 {
            // An unreadable snapshot is not proof of unload; keep polling.
            if let statuses = await routerStatesSnapshot(), statuses[modelId] != .loaded { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw EngineFailure.modelUnloadFailed(modelId)
    }

    /// `GET /models` → `id` → status. The router reports `unloaded`, `loading`,
    /// `loaded` and `sleeping` per model; this is the only honest source of the
    /// "is this model warm" question.
    ///
    /// Returns `nil` when the router could not be asked. An empty dictionary is
    /// a valid answer ("no models"), so callers can tell "nothing loaded" from
    /// "unknown" and keep their last known state on the latter.
    private func routerStatesSnapshot() async -> [String: RouterModelStatus]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(internalToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await NetworkProxy.directSession().data(for: request) else {
            Self.logger.debug("router states unavailable: request failed")
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            Self.logger.debug("router states unavailable: HTTP \(code, privacy: .public)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else {
            Self.logger.debug("router states unavailable: malformed body")
            return nil
        }
        var result: [String: RouterModelStatus] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String else { continue }
            let raw = (entry["status"] as? [String: Any])?["value"] as? String ?? "unloaded"
            result[id] = RouterModelStatus(rawValue: raw) ?? .unloaded
        }
        return result
    }

    private func routerContextLength(_ modelId: String) async -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(internalToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await NetworkProxy.directSession().data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]],
              let entry = entries.first(where: { ($0["id"] as? String) == modelId }),
              let meta = entry["meta"] as? [String: Any],
              let context = meta["n_ctx"] as? Int, context > 0 else {
            return nil
        }
        return context
    }

    /// Records the context the engine really allocated, so the UI and the Codex
    /// catalog stop advertising a configured number the engine never accepted.
    private func recordAppliedContext(_ context: Int?, for model: LocalModel) {
        guard let context, context > 0, context != model.configuredContext else { return }
        var updated = model
        updated.configuredContext = context
        LocalModelStore.shared.addOrUpdateModel(updated)
    }

    // MARK: - Monitoring

    /// Periodic liveness check. Without it a crashed router left `ready` rows and
    /// gateway routes behind until the next manual action.
    private func startMonitoring(generation operation: Int) {
        stopMonitoring()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.monitorTick(generation: operation)
            }
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func monitorTick(generation operation: Int) async {
        guard generation == operation, let p = process else { return }
        guard p.isRunning else {
            handleProcessTermination(exitCode: p.terminationStatus, generation: operation)
            return
        }
        let healthy = await checkHealth(port: port, token: internalToken)
        guard generation == operation, process === p else { return }
        guard healthy else { return }

        guard let statuses = await routerStatesSnapshot() else {
            // The router is healthy but its model list is unreadable. Treat the
            // state as unknown instead of pretending every model was unloaded.
            Self.logger.debug("router states unavailable; keeping last known model statuses")
            return
        }
        guard generation == operation, process === p else { return }
        // If the router cannot confirm any loaded model, never keep stale Ready
        // routes. A later successful snapshot will republish actual loaded ones.
        routerStates = statuses
        var changed = false

        // Map the router's own view onto the registry: an idle-unloaded model is
        // `installed`, not `ready`.
        for (id, routerState) in statuses {
            guard let model = LocalModelStore.shared.models.first(where: { $0.id == id }) else { continue }
            let desired: ModelRuntimeStatus
            switch routerState {
            case .loaded: desired = .ready
            case .loading: desired = .loading
            case .unloaded, .sleeping: desired = .installed
            case .failed: desired = .error
            }
            if model.runtimeStatus != desired {
                LocalModelStore.shared.updateModelStatus(id: id, status: desired)
                changed = true
            }
        }
        if statuses.isEmpty {
            changed = LocalModelStore.shared.models.contains { $0.runtimeStatus.isTransient }
            LocalModelStore.shared.normalizeRuntimeStates()
        } else {
            for model in LocalModelStore.shared.models where model.runtimeStatus.isTransient && statuses[model.id] == nil {
                LocalModelStore.shared.updateModelStatus(id: model.id, status: .installed)
                changed = true
            }
        }
        if changed { publishLocalRoutes() }
    }

    // MARK: - Health of processes left behind

    /// Ports `startEngine` may hand to a router. A process listening outside
    /// this range was not started by this app.
    nonisolated private static let enginePortRange = 18_318...18_348

    private struct PSRow {
        let pid: pid_t
        let ppid: pid_t
        let command: String
    }

    /// Kills engine processes left behind by a previous run.
    ///
    /// A crash or a force-quit can orphan the router, which keeps the model
    /// resident. Ownership is proven by the runtime binary path plus the
    /// loopback host; a live parent that is not this app means the process
    /// belongs to someone else and is left alone.
    func reapOrphanedEngines() async {
        guard process == nil else { return }
        let binary = RuntimeStore.shared.activeBinaryURL?.path ?? ""
        guard !binary.isEmpty else { return }
        let modelsPath = LocalPaths.models.path
        let appPID = getpid()
        let worker = Task.detached(priority: .utility) {
            await Self.reapOrphanedEngines(binary: binary, modelsPath: modelsPath, appPID: appPID)
        }
        await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    nonisolated private static func reapOrphanedEngines(
        binary: String,
        modelsPath: String,
        appPID: pid_t
    ) async {
        guard !binary.isEmpty else { return }
        guard let result = try? await ShellService.run(
            "/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 2
        ), result.exitCode == 0 else { return }

        let pids = enginePIDsToReap(
            fromPSOutput: result.stdout, binary: binary, modelsPath: modelsPath, appPID: appPID
        )
        guard !Task.isCancelled, !pids.isEmpty else { return }
        for pid in pids { signalEngine(pid: pid, signal: SIGTERM) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        for pid in pids where kill(pid, 0) == 0 {
            signalEngine(pid: pid, signal: SIGKILL)
        }
    }

    /// Blocking twin of `reapOrphanedEngines`, used from `stopSync` and
    /// `applicationWillTerminate`: Swift concurrency is already shutting down
    /// there, so the async reaper cannot be awaited.
    nonisolated private static func reapOrphanedEnginesSync(binary: String) {
        guard !binary.isEmpty, let output = psOutput() else { return }
        let pids = enginePIDsToReap(
            fromPSOutput: output, binary: binary, modelsPath: LocalPaths.models.path, appPID: getpid()
        )
        guard !pids.isEmpty else { return }
        for pid in pids { signalEngine(pid: pid, signal: SIGTERM) }
        usleep(50_000)
        for pid in pids where kill(pid, 0) == 0 {
            signalEngine(pid: pid, signal: SIGKILL)
        }
    }

    /// One bounded `ps` read. The process table is local and small, but quit
    /// must not hang on a wedged `ps`, so a watchdog terminates it.
    nonisolated private static func psOutput(timeout: TimeInterval = 0.1) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            return nil
        }
        // Two-stage watchdog: SIGTERM, then SIGKILL if `ps` is stuck. Without
        // the second stage a wedged `ps` would block the quit path forever.
        let watchdog = DispatchWorkItem {
            if ps.isRunning { ps.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                if ps.isRunning { kill(ps.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        watchdog.cancel()
        guard ps.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Selects only engines this app owns and that nobody is going to clean up:
    /// a router orphaned on launchd (pid 1) or one whose parent is gone, its
    /// model children, and model children already orphaned by an earlier kill.
    /// A process under a live parent is never touched, even if its command line
    /// mentions our binary.
    nonisolated private static func enginePIDsToReap(
        fromPSOutput output: String,
        binary: String,
        modelsPath: String,
        appPID: pid_t
    ) -> [pid_t] {
        guard !binary.isEmpty else { return [] }
        let rows = output.split(separator: "\n").compactMap { line -> PSRow? in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = pid_t(fields[0]),
                  let ppid = pid_t(fields[1]) else { return nil }
            return PSRow(pid: pid, ppid: ppid, command: String(fields[2]))
        }
        guard !rows.isEmpty else { return [] }
        let livePIDs = Set(rows.map(\.pid))

        let routers = rows.filter { row in
            guard row.pid != appPID, row.ppid != appPID else { return false }
            guard row.command.contains(binary), bindsLoopback(row.command),
                  let port = portArgument(in: row.command),
                  enginePortRange.contains(port) else { return false }
            return row.ppid == 1 || !livePIDs.contains(row.ppid)
        }
        let routerPIDs = Set(routers.map(\.pid))

        // A router's model children listen on an ephemeral port and load a
        // model from our own models folder; the parent link proves ownership.
        let children = rows.filter { row in
            routerPIDs.contains(row.ppid)
                && row.command.contains(binary)
                && (!modelsPath.isEmpty && row.command.contains(modelsPath))
        }

        // A router SIGKILLed without group cleanup leaves its child on pid 1.
        let orphanChildren = rows.filter { row in
            guard row.pid != appPID, row.ppid == 1 else { return false }
            guard !routerPIDs.contains(row.pid) else { return false }
            return row.command.contains(binary)
                && !row.command.contains("--models-preset")
                && (!modelsPath.isEmpty && row.command.contains(modelsPath))
        }

        return Set(routers.map(\.pid) + children.map(\.pid) + orphanChildren.map(\.pid)).sorted()
    }

    nonisolated private static func bindsLoopback(_ command: String) -> Bool {
        let tokens = command.split(separator: " ")
        for (index, token) in tokens.enumerated() {
            if token == "--host", index + 1 < tokens.count, tokens[index + 1] == "127.0.0.1" {
                return true
            }
            if token == "--host=127.0.0.1" { return true }
        }
        return false
    }

    nonisolated private static func portArgument(in command: String) -> Int? {
        let tokens = command.split(separator: " ")
        for (index, token) in tokens.enumerated() {
            if token == "--port", index + 1 < tokens.count, let port = Int(tokens[index + 1]) {
                return port
            }
            if token.hasPrefix("--port="), let port = Int(token.dropFirst("--port=".count)) {
                return port
            }
        }
        return nil
    }

    /// Signals the router's process group when it exists, falling back to the
    /// single pid when the group is already gone.
    nonisolated private static func signalEngine(pid: pid_t, signal: Int32) {
        if kill(-pid, signal) == 0 { return }
        let groupErrno = errno
        guard groupErrno == ESRCH || groupErrno == EPERM else { return }
        kill(pid, signal)
    }

    // MARK: - Settings

    /// How a settings edit has to be applied.
    enum SettingsChangeKind: Equatable {
        /// Nothing changed.
        case none
        /// Only request-level sampling defaults: the preset covers them, and
        /// they take effect for the next model load without touching a running
        /// engine.
        case sampling
        /// Engine-level values (context, KV type, offload, threads, template):
        /// these are command-line flags of the model process, so applying them
        /// requires restarting the engine.
        case engine
    }

    /// Classifies an edit so the sheet can offer "apply on restart" instead of
    /// silently killing every in-flight request on Save.
    nonisolated static func classifySettingsChange(
        from old: LocalModelSettings,
        to new: LocalModelSettings
    ) -> SettingsChangeKind {
        if old == new { return .none }
        let engineChanged = old.contextLength != new.contextLength
            || old.gpuOffloadLayers != new.gpuOffloadLayers
            || old.cpuThreads != new.cpuThreads
            || old.flashAttention != new.flashAttention
            || old.kvCacheType != new.kvCacheType
            || old.batchSize != new.batchSize
            || old.chatTemplate != new.chatTemplate
            || old.reasoningEnabled != new.reasoningEnabled
        if engineChanged { return .engine }
        let samplingChanged = old.temperature != new.temperature
            || old.topP != new.topP
            || old.topK != new.topK
            || old.repeatPenalty != new.repeatPenalty
            || old.maxOutputTokens != new.maxOutputTokens
            || old.seed != new.seed
        return samplingChanged ? .sampling : .none
    }

    /// True when the saved settings differ from the preset the running engine
    /// was started with.
    var settingsPendingRestart: Bool {
        guard process != nil else { return false }
        guard let appliedPresetDigest else { return true }
        return appliedPresetDigest != presetDigest()
    }

    /// Restarts the engine so a settings change takes effect. Returns the error
    /// instead of swallowing it, so the sheet can show why nothing changed.
    @discardableResult
    func applySettingsChange(modelId: String? = nil) async -> Error? {
        engineError = nil
        // A settings sheet names its target; global runtime settings keep the
        // current-model fallback. Never substitute the first installed model
        // for an explicit per-model edit.
        let selected = modelId.flatMap { id in
            LocalModelStore.shared.models.first(where: { $0.id == id })
        }
        if modelId != nil && selected == nil {
            return EngineFailure.modelFileMissing(modelId ?? "")
        }
        let model = selected ?? currentModel.flatMap { current in
            LocalModelStore.shared.models.first(where: { $0.id == current.id })
        }
            ?? LocalModelStore.shared.models.first(where: { $0.runtimeStatus == .ready })
            ?? LocalModelStore.shared.models.first
        guard let model else { return nil }

        let targetIsActive = modelId == nil || currentModel?.id == modelId
            || modelId.map { routerStates[$0] == .loaded } == true
        guard (status.isRunning || status.isStarting) && targetIsActive else {
            // Nothing to restart: the next start reads the new preset anyway.
            // A failing preset write is reported now instead of surfacing as a
            // mysterious start failure later.
            do {
                _ = try writeModelsPreset()
                return nil
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                engineError = message
                return error
            }
        }

        await stop()
        do {
            try await loadModel(model)
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            engineError = message
            return error
        }
    }

    // MARK: - Router configuration

    /// How many models the router may keep loaded at once (§11.4: one by
    /// default, so a second request unloads the first instead of exhausting RAM).
    static var modelsMaxConcurrent: Int {
        let value = UserDefaults.standard.integer(forKey: "localAIModelsMax")
        return value > 0 ? value : 1
    }

    /// Slots served in parallel by the engine (§12.1 Parallel Requests).
    static var parallelRequests: Int {
        let value = UserDefaults.standard.integer(forKey: "localAIParallel")
        return value > 0 ? min(value, 16) : 1
    }

    /// Idle seconds after which an unused model is unloaded (§12.1 Keep Alive).
    /// `0` keeps it resident forever.
    static var idleUnloadSeconds: Int {
        max(0, UserDefaults.standard.integer(forKey: "localAIIdleUnloadSeconds"))
    }

    /// Builds the router preset: one section per installed model, carrying the
    /// per-model settings the router cannot receive as command-line flags.
    ///
    /// Written on every launch, so a settings change takes effect on the next
    /// engine start without touching the registry format.
    @discardableResult
    private func writeModelsPreset() throws -> URL {
        let models = LocalModelStore.shared.models
        let lines = Self.presetLines(
            models: models,
            modelsDirectory: LocalModelStore.shared.modelsDirectory,
            backend: LocalHardwareService.shared.hardwareInfo.recommendedBackend,
            cpuCores: LocalHardwareService.shared.hardwareInfo.cpuCores
        )
        guard lines.count > 1 else {
            throw EngineFailure.noInstalledModels
        }

        let url = LocalPaths.enginePreset
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Builds the INI body. Pure on purpose, so the format is testable without
    /// starting an engine.
    ///
    /// Every key here was verified against the pinned engine: an unknown option
    /// makes the router refuse to start (`option '<x>' not recognized in preset`),
    /// so this list is deliberately conservative.
    nonisolated static func presetLines(
        models: [LocalModel],
        modelsDirectory: URL,
        backend: InferenceBackend,
        cpuCores: Int
    ) -> [String] {
        var lines: [String] = []
        lines.append("# Generated by Melon Tools. Do not edit: rewritten on every launch.")

        for model in models {
            let files = model.fileURLs(in: modelsDirectory)
            guard let fileURL = files.first,
                  FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let settings = model.userSettings
            // The preset is a flat INI: a newline in any value would end the
            // current key and let it define arbitrary options for the model.
            let identifier = iniBare(model.id)

            lines.append("")
            lines.append("[\(identifier)]")
            // A split model is loaded through its first shard; the engine finds
            // the remaining parts by the `-NNNNN-of-NNNNN` name.
            lines.append("model = \(iniValue(fileURL.path))")
            lines.append("alias = \(identifier)")
            lines.append("ctx-size = \(min(max(512, settings.contextLength), 1_048_576))")
            lines.append("batch-size = \(min(max(1, settings.batchSize), 8_192))")
            let offload = min(max(settings.gpuOffloadLayers ?? 99, 0), 999)
            lines.append(backend == .metal
                         ? "n-gpu-layers = \(offload)"
                         : "n-gpu-layers = 0")
            lines.append("flash-attn = \(settings.flashAttention ? "on" : "off")")
            if let template = settings.chatTemplate, !template.isEmpty, template != "auto" {
                lines.append("chat-template = \(iniValue(template))")
            }
            lines.append("reasoning = \(settings.isReasoningOn ? "on" : "off")")
            // llama.cpp ignores an unknown cache type or falls back to f16; an
            // allowlist keeps a typo from reaching the engine as a mystery.
            let cacheType = allowedKvCacheTypes.contains(settings.kvCacheType)
                ? settings.kvCacheType
                : "f16"
            lines.append("cache-type-k = \(cacheType)")
            lines.append("cache-type-v = \(cacheType)")
            let threads = settings.cpuThreads ?? max(1, cpuCores)
            lines.append("threads = \(min(max(1, threads), 1_024))")

            // Sampling defaults (§12.2). Without these the saved temperature,
            // top-p, top-k, repeat penalty and output budget never reached the
            // engine, so the sliders were decorative.
            lines.append("temperature = \(clamp(settings.temperature, 0, 2))")
            lines.append("top-p = \(clamp(settings.topP, 0, 1))")
            lines.append("top-k = \(min(max(0, settings.topK), 1_000))")
            lines.append("repeat-penalty = \(clamp(settings.repeatPenalty, 0.1, 4))")
            if let maxOutput = settings.maxOutputTokens, maxOutput > 0 {
                lines.append("n-predict = \(min(maxOutput, 131_072))")
            }
            if let seed = settings.seed {
                lines.append("seed = \(seed)")
            }
        }
        return lines
    }

    /// Cache types llama.cpp understands; anything else is dropped to `f16`.
    nonisolated private static let allowedKvCacheTypes: Set<String> = [
        "f16", "f32", "bf16", "q8_0", "q4_0", "q4_1", "q5_0", "q5_1", "iq4_nl",
    ]

    /// INI value sanitiser: one line, no control characters, bounded length.
    nonisolated private static func iniValue(_ raw: String) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\0", with: "")
        return String(flattened.prefix(1_024))
    }

    /// Section name / alias sanitiser: brackets and newlines would break the
    /// `[id]` line, so they are folded into a dash.
    nonisolated private static func iniBare(_ raw: String) -> String {
        let folded = raw
            .replacingOccurrences(of: "[", with: "-")
            .replacingOccurrences(of: "]", with: "-")
            .replacingOccurrences(of: "\r", with: "-")
            .replacingOccurrences(of: "\n", with: "-")
        let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "model" : trimmed).prefix(128))
    }

    nonisolated private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> String {
        // `min`/`max` return the NaN operand, which would reach the INI file as
        // `temperature = nan`.
        guard value.isFinite else { return String(format: "%.2f", lower) }
        let clamped = min(max(value, lower), upper)
        // Keep the INI value short and locale-independent.
        return String(format: "%.2f", clamped)
    }

    /// SHA-256 of the preset body: "what the running engine was told".
    private func presetDigest() -> String? {
        let lines = Self.presetLines(
            models: LocalModelStore.shared.models,
            modelsDirectory: LocalModelStore.shared.modelsDirectory,
            backend: LocalHardwareService.shared.hardwareInfo.recommendedBackend,
            cpuCores: LocalHardwareService.shared.hardwareInfo.cpuCores
        )
        let body = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return digest
    }

    private static func readAppliedPresetDigest() -> String? {
        guard let text = try? String(contentsOf: LocalPaths.appliedPresetDigest, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func storeAppliedPresetDigest(_ digest: String?) {
        guard let digest else { return }
        try? digest.write(to: LocalPaths.appliedPresetDigest, atomically: true, encoding: .utf8)
    }

    // MARK: - Metrics

    private func startMetricsPolling(modelId: String) {
        stopMetricsPolling()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Read the router state the monitor already published instead of
                // making a second `/models` request every tick: a stale or
                // timed-out answer used to skip the fetch and freeze the cards.
                let state = await MainActor.run { self.routerStates[modelId] }
                if state == .loaded || state == nil {
                    let result = await Self.fetchMetrics(
                        port: self.port,
                        token: self.internalToken,
                        modelId: modelId
                    )
                    await MainActor.run {
                        let live = Self.withLiveRates(result.metrics, baseline: self.metricsBaseline)
                        self.metrics = live
                        // Keep the displayed snapshot as the next baseline so an
                        // idle poll reuses the last real rate instead of the
                        // engine's session average.
                        self.metricsBaseline = live
                        self.metricsError = result.error
                    }
                } else {
                    await MainActor.run {
                        self.metrics = nil
                        self.metricsBaseline = nil
                        self.metricsError = state == .sleeping || state == .unloaded
                            ? L("Model is not loaded, so the engine reports no metrics.")
                            : nil
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopMetricsPolling() {
        metricsTask?.cancel()
        metricsTask = nil
        metricsBaseline = nil
        metrics = nil
        metricsError = nil
    }

    /// Parses the Prometheus exposition from `llama-server --metrics`.
    ///
    /// The router serves metrics **per model** and answers `400 model name is
    /// missing from the request` without the query parameter, which is why the
    /// old `/metrics` poll never produced a number.
    static func fetchMetrics(port: Int, token: String, modelId: String?) async -> (metrics: InferenceMetrics?, error: String?) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/metrics"
        if let modelId, !modelId.isEmpty {
            components.queryItems = [URLQueryItem(name: "model", value: modelId)]
        }
        guard let url = components.url else { return (nil, L("Invalid metrics URL.")) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        // `URLSession` caches loopback GETs: a stale `/metrics` body kept the
        // cards at their first sample while the engine kept generating.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await NetworkProxy.directSession().data(for: request),
              let http = response as? HTTPURLResponse else {
            return (nil, L("The engine did not answer the metrics request."))
        }
        guard http.statusCode == 200 else {
            return (nil, String(format: L("Metrics request failed with HTTP %d."), http.statusCode))
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let snapshot = parseMetrics(text) else {
            return (nil, L("The engine returned an unrecognised metrics payload."))
        }
        return (snapshot, nil)
    }

    /// Parses Prometheus text into the numbers the UI shows. Labels are stripped
    /// (`name{a="b"} 1` → `name`), and a counter is summed across label sets.
    nonisolated static func parseMetrics(_ text: String, now: Date = Date()) -> InferenceMetrics? {
        var values: [String: Double] = [:]
        var sawMetric = false

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let spaceIndex = line.lastIndex(of: " ") else { continue }
            let namePart = String(line[..<spaceIndex])
            let valuePart = String(line[line.index(after: spaceIndex)...])
            guard let value = Double(valuePart.trimmingCharacters(in: .whitespaces)),
                  value.isFinite, value >= 0, value <= 9.0e15 else { continue }
            let baseName: String
            if let brace = namePart.firstIndex(of: "{") {
                baseName = String(namePart[..<brace])
            } else {
                baseName = namePart
            }
            values[baseName] = (values[baseName] ?? 0) + value
            sawMetric = true
        }

        guard sawMetric else { return nil }
        var snapshot = InferenceMetrics()
        snapshot.promptTokens = Self.counter(values["llamacpp:prompt_tokens_total"])
        snapshot.predictedTokens = Self.counter(values["llamacpp:tokens_predicted_total"])
        // The engine writes the throughput gauges when a task finishes and
        // reports 0 for the whole generation, so a 0 gauge is "no sample yet",
        // not "0 tok/s". Fall back to the averages over the counters, but only
        // once they cover a meaningful interval: 2 tokens divided by a
        // near-zero `*_seconds_total` right after a start used to show
        // 1000000.0 tok/s.
        if let rate = Self.plausibleRate(values["llamacpp:prompt_tokens_seconds"] ?? 0) {
            snapshot.promptPerSecond = rate
        } else if let seconds = values["llamacpp:prompt_seconds_total"], seconds >= 1 {
            snapshot.promptPerSecond =
                Self.plausibleRate(Double(snapshot.promptTokens) / seconds) ?? 0
        }
        if let rate = Self.plausibleRate(values["llamacpp:predicted_tokens_seconds"] ?? 0) {
            snapshot.predictedPerSecond = rate
        } else if let seconds = values["llamacpp:tokens_predicted_seconds_total"], seconds >= 1 {
            snapshot.predictedPerSecond =
                Self.plausibleRate(Double(snapshot.predictedTokens) / seconds) ?? 0
        }
        snapshot.updatedAt = now
        return snapshot
    }

    /// A counter from the exposition, clamped so `Int(_:)` can never trap.
    /// `nan`/`inf` and absurd values come from a broken or foreign `/metrics`.
    nonisolated static func counter(_ value: Double?) -> Int {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value >= 9.0e15 ? 9_000_000_000_000_000 : Int(value)
    }

    /// A real tokens/s figure. Anything outside this range is a broken
    /// exposition (a counter divided by a near-zero elapsed time), not speed.
    nonisolated static func plausibleRate(_ value: Double) -> Double? {
        guard value.isFinite, value > 0, value <= 100_000 else { return nil }
        return value
    }

    /// Replaces the engine's average rates with the rate seen since the last
    /// poll. The counters are live even though the `*_tokens_seconds` gauges
    /// are not, so this is what makes the cards move during a generation. A
    /// quiet interval keeps the last known rate instead of flashing 0.
    nonisolated static func withLiveRates(
        _ metrics: InferenceMetrics?,
        baseline: InferenceMetrics?
    ) -> InferenceMetrics? {
        guard var current = metrics else { return nil }
        guard let baseline else { return current }
        let elapsed = current.updatedAt.timeIntervalSince(baseline.updatedAt)
        guard elapsed >= 1 else {
            // Too soon for a delta: keep what the card showed a moment ago.
            current.predictedPerSecond = baseline.predictedPerSecond
            current.promptPerSecond = baseline.promptPerSecond
            return current
        }
        let predicted = Double(current.predictedTokens - baseline.predictedTokens) / elapsed
        let prompt = Double(current.promptTokens - baseline.promptTokens) / elapsed
        // A positive delta is the live rate. A zero delta is an idle interval:
        // keep the last known rate. A negative delta means the engine
        // restarted: keep the exposition value for this sample.
        if predicted > 0 {
            current.predictedPerSecond = Self.plausibleRate(predicted) ?? baseline.predictedPerSecond
        } else if predicted == 0 {
            current.predictedPerSecond = baseline.predictedPerSecond
        }
        if prompt > 0 {
            current.promptPerSecond = Self.plausibleRate(prompt) ?? baseline.promptPerSecond
        } else if prompt == 0 {
            current.promptPerSecond = baseline.promptPerSecond
        }
        return current
    }

    // MARK: - Logs

    private func attachLogs(to process: Process, model: LocalModel) {
        logSink.reset(
            fileURL: LocalPaths.engineLog,
            redactions: [internalToken]
        )
        // A new engine process starts a new console. Keeping the previous run's
        // lines made the pane look like it was still generating while the
        // metrics of the fresh process were close to zero.
        logLines = []
        logRevision &+= 1
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // `readabilityHandler` runs on a private queue: hand it the sink itself
        // (thread-safe) instead of the MainActor-isolated service.
        let sink = logSink
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            sink.append(data)
        }
        logSink.startFlushing()
    }

    private func closeLogSink() {
        logSink.stopFlushing()
    }

    // MARK: - Errors

    private static func errorMessage(from data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["message"] as? String { return message }
        }
        let text = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "HTTP \(status)" : text
    }
}

/// Reasons a launch can fail, with messages a user can act on.
enum EngineFailure: LocalizedError {
    case binaryMissing
    case modelFileMissing(String)
    case noInstalledModels
    case spawnFailed(String)
    case healthTimeout
    case engineExited(exitCode: Int32?)
    case modelLoadFailed(String, String)
    case modelLoadTimeout(String)
    case modelUnloadFailed(String)
    case portUnavailable

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return L("llama-server runtime binary not found. Install a runtime in Settings or pick a binary manually.")
        case .modelFileMissing(let path):
            return String(format: L("Model file does not exist at %@"), path)
        case .noInstalledModels:
            return L("No installed model files to serve.")
        case .spawnFailed(let detail):
            return String(format: L("Failed to start llama-server: %@"), detail)
        case .healthTimeout:
            return L("Engine did not respond within health check timeout.")
        case .engineExited(let code):
            if let code {
                return String(format: L("The engine exited unexpectedly (status %d)."), code)
            }
            return L("The engine exited unexpectedly.")
        case .modelLoadFailed(let id, let detail):
            return String(format: L("The engine could not load %@: %@"), id, detail)
        case .modelLoadTimeout(let id):
            return String(format: L("The engine did not finish loading %@ in time."), id)
        case .modelUnloadFailed(let id):
            return String(format: L("The engine did not unload %@."), id)
        case .portUnavailable:
            return L("No free local port in the 18318–18348 range. Another program holds all of them.")
        }
    }
}

// MARK: - Log sink

/// Collects engine output off the main thread: bounded ring buffer for the UI,
/// rotating file on disk, batched notifications, and redaction of secrets.
///
/// The previous implementation wrote straight into an append-only file and never
/// filled `logLines`, so the Console pane and "Copy Logs" were always empty.
final class EngineLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var pendingPartial = Data()
    private var fileHandle: FileHandle?
    private var fileBytes: UInt64 = 0
    private var fileURL: URL?
    private var redactions: [String] = []
    private var flushTask: Task<Void, Never>?
    private var lastFlush = Date.distantPast
    private var dirty = false

    /// Ring size: enough to diagnose a failed launch, small enough to render.
    private let maxLines = 2000
    /// Rotate before the file becomes a multi-gigabyte liability.
    private let maxFileBytes: UInt64 = 4 * 1024 * 1024

    var onFlush: (([String]) -> Void)?

    func reset(fileURL: URL, redactions: [String]) {
        lock.lock()
        self.redactions = redactions
        self.fileURL = fileURL
        pendingPartial.removeAll(keepingCapacity: true)
        lines.removeAll(keepingCapacity: true)
        dirty = false
        try? fileHandle?.close()
        rotateIfNeeded(fileURL)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        fileBytes = UInt64(max(0, size))
        lock.unlock()
    }

    private func rotateIfNeeded(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, UInt64(size) >= maxFileBytes else {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            return
        }
        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func append(_ data: Data) {
        lock.lock()
        pendingPartial.append(data)
        let newLines = extractLines()
        if !newLines.isEmpty {
            lines.append(contentsOf: newLines)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
            write(newLines)
            dirty = true
        }
        let shouldFlush = dirty && Date().timeIntervalSince(lastFlush) >= 0.1
        if shouldFlush {
            lastFlush = Date()
            dirty = false
            let snapshot = lines
            lock.unlock()
            onFlush?(snapshot)
            return
        }
        lock.unlock()
    }

    /// Splits complete lines out of the partial buffer; a partial line that grows
    /// past the limit is flushed as-is so a broken writer cannot grow it forever.
    private func extractLines() -> [String] {
        var result: [String] = []
        while let newline = pendingPartial.firstIndex(of: 0x0A) {
            let lineData = pendingPartial[pendingPartial.startIndex..<newline]
            pendingPartial.removeSubrange(pendingPartial.startIndex...newline)
            result.append(decode(Array(lineData)))
        }
        if pendingPartial.count > 64 * 1024 {
            result.append(decode(Array(pendingPartial)))
            pendingPartial.removeAll(keepingCapacity: true)
        }
        return result
    }

    private func decode(_ bytes: [UInt8]) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        return redact(text)
    }

    /// Masks the loopback API key and any Hugging Face token shape that could
    /// reach the log through an error message.
    private func redact(_ text: String) -> String {
        var result = text
        for secret in redactions where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "«redacted»")
        }
        if let regex = try? NSRegularExpression(pattern: #"hf_[A-Za-z0-9]{16,}"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: "«redacted»"
            )
        }
        return result
    }

    private func write(_ newLines: [String]) {
        guard let fileURL else { return }
        let body = newLines.joined(separator: "\n") + "\n"
        guard let data = body.data(using: .utf8) else { return }
        // A single noisy write must neither exceed the cap nor permanently
        // disable diagnostics. Retain the newest bytes and rotate in-session.
        let bounded = Data(data.suffix(Int(maxFileBytes)))
        if fileBytes + UInt64(bounded.count) > maxFileBytes {
            try? fileHandle?.close()
            let backup = fileURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            fileBytes = 0
        }
        try? fileHandle?.write(contentsOf: bounded)
        fileBytes += UInt64(bounded.count)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
        pendingPartial.removeAll(keepingCapacity: true)
        try? fileHandle?.close()
        fileHandle = nil
        // Hold the lock across truncate/reopen so append cannot race a clear.
        let url = fileURL ?? LocalPaths.engineLog
        fileURL = url
        AtomicFileOps.removeIfExists(url)
        AtomicFileOps.removeIfExists(url.appendingPathExtension("1"))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileBytes = 0
    }

    /// Emits the remaining buffered lines once the process is gone.
    func startFlushing() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                let snapshot: [String]?
                self.lock.lock()
                let shouldFlush = self.dirty
                if shouldFlush { self.dirty = false }
                snapshot = shouldFlush ? self.lines : nil
                self.lock.unlock()
                if let snapshot { self.onFlush?(snapshot) }
            }
        }
    }

    func stopFlushing() {
        flushTask?.cancel()
        flushTask = nil
        lock.lock()
        let snapshot = lines
        let created = FileManager.default.fileExists(atPath: LocalPaths.engineLog.path)
        lock.unlock()
        if created { onFlush?(snapshot) }
    }
}
