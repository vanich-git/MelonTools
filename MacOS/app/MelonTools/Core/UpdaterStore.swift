import AppKit
import CryptoKit
import Foundation
import os

/// Bytes already received for the update, so the sheet can show a real
/// progress bar instead of an indeterminate spinner.
struct UpdateDownloadProgress: Equatable {
    var received: Int64
    var total: Int64
    var bytesPerSecond: Double

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(received) / Double(total))
    }
}

/// GitHub-based self-update: checks the latest release, downloads the macOS
/// DMG, verifies SHA256 and hands the swap to a detached script that runs
/// after the app quits.
///
/// Public HTTPS endpoints only (no tokens, no SSH):
/// `api.github.com` for the release JSON and `github.com` /
/// `objects.githubusercontent.com` / `release-assets.githubusercontent.com`
/// for the download.
@MainActor
final class UpdaterStore: ObservableObject {
    static let shared = UpdaterStore()

    private static let logger = Logger(subsystem: "dev.melontools.app", category: "Updater")

    static let releaseAPI = URL(string: "https://api.github.com/repos/vanich-git/MelonTools/releases/latest")!
    nonisolated static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String, String) // version, notes
        case working(String)
        case failed(String)
    }

    enum UpdaterError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var download: UpdateDownloadProgress?
    @Published var sheetPresented = false

    private var assetURL: URL?
    private var assetDigest: String?
    private var busy = false
    private var lastProgressAt: Date?

    /// How often the running app wakes up to ask for updates. The throttle
    /// below still owns the real cadence: a non-manual check within one hour
    /// of the last successful one is a no-op.
    nonisolated static let periodicCheckInterval: TimeInterval = 3600
    /// Only a successful non-manual check counts toward this throttle.
    nonisolated static let automaticCheckThrottle: TimeInterval = 3600

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    // MARK: - Pure helpers (unit-tested)

    enum Version {
        /// SemVer precedence: `1.4.10 > 1.4.9`, `1.4 == 1.4.0`, and a final
        /// release outranks its own pre-release (`6.0.0 > 6.0.0-rc.1`). Without
        /// the last rule a build shipped as `-rc.N` would never be offered the
        /// stable release it belongs to.
        nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
            let (candidateCore, candidatePre) = parts(candidate)
            let (currentCore, currentPre) = parts(current)
            for index in 0..<max(candidateCore.count, currentCore.count) {
                let l = index < candidateCore.count ? candidateCore[index] : 0
                let r = index < currentCore.count ? currentCore[index] : 0
                if l != r { return l > r }
            }
            return comparePrerelease(candidatePre, currentPre) == .orderedDescending
        }

        /// Splits `1.2.3-rc.4+build` into numeric core segments and pre-release
        /// identifiers. Build metadata is dropped: SemVer ignores it.
        nonisolated static func parts(_ text: String) -> ([UInt64], [String]) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? trimmed
            let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = (pieces.first.map(String.init) ?? withoutBuild)
                .split(separator: ".")
                .map { UInt64($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            let pre = pieces.count > 1 && !pieces[1].isEmpty
                ? pieces[1].split(separator: ".").map(String.init)
                : []
            return (core, pre)
        }

        /// No pre-release outranks any pre-release; numeric identifiers compare
        /// numerically (`rc.10 > rc.9`) and rank below alphanumeric ones; the
        /// shorter list wins when every shared identifier is equal.
        nonisolated static func comparePrerelease(_ left: [String], _ right: [String]) -> ComparisonResult {
            if left.isEmpty && right.isEmpty { return .orderedSame }
            if left.isEmpty { return .orderedDescending }
            if right.isEmpty { return .orderedAscending }
            for index in 0..<max(left.count, right.count) {
                guard index < left.count else { return .orderedAscending }
                guard index < right.count else { return .orderedDescending }
                let l = left[index]
                let r = right[index]
                let result: ComparisonResult
                switch (UInt64(l), UInt64(r)) {
                case let (ln?, rn?):
                    result = ln == rn ? .orderedSame : (ln < rn ? .orderedAscending : .orderedDescending)
                case (.some, .none):
                    result = .orderedAscending
                case (.none, .some):
                    result = .orderedDescending
                case (.none, .none):
                    result = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
                }
                if result != .orderedSame { return result }
            }
            return .orderedSame
        }
    }

    /// Whether a non-manual check may hit the network. Pure so the periodic
    /// timer cadence (1 h) and the hourly throttle stay independently testable.
    nonisolated static func shouldCheckAutomatically(lastCheck: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastCheck) > automaticCheckThrottle
    }

    nonisolated static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && allowedHosts.contains(url.host ?? "")
    }

    /// First token of a `.sha256` file, when it is a 64-char hex string.
    nonisolated static func parseSha256File(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).first else {
            return nil
        }
        let hex = String(token).lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Checking

    func check(manual: Bool) async {
        guard !busy else { return }
        if !manual {
            let last = UserDefaults.standard.object(forKey: "updaterLastCheck") as? Date ?? .distantPast
            guard Self.shouldCheckAutomatically(lastCheck: last, now: Date()) else { return }
        }
        busy = true
        if manual { phase = .checking }
        defer { busy = false }

        do {
            var request = URLRequest(url: Self.releaseAPI)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MelonTools/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await NetworkProxy.session().data(for: request)
            guard let finalURL = response.url, Self.isAllowed(finalURL) else {
                throw UpdaterError.message(L("The update server answered from a disallowed host."))
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdaterError.message(L("The update server answered with an unexpected status."))
            }
            // Only a successful check counts toward the daily throttle.
            UserDefaults.standard.set(Date(), forKey: "updaterLastCheck")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UpdaterError.message(L("Malformed update response."))
            }
            let tag = (json["tag_name"] as? String) ?? ""
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (json["body"] as? String) ?? ""

            guard Self.Version.isNewer(version, than: currentVersion) else {
                assetURL = nil
                assetDigest = nil
                phase = .upToDate(currentVersion)
                Self.logger.info("up to date: \(self.currentVersion, privacy: .public)")
                return
            }
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            guard let asset = assets.first(where: { item in
                let name = (item["name"] as? String) ?? ""
                return name.hasPrefix("MelonTools-") && name.hasSuffix(".dmg")
            }),
            let urlString = asset["browser_download_url"] as? String,
            let url = URL(string: urlString),
            Self.isAllowed(url) else {
                throw UpdaterError.message(L("This release has no installer for macOS."))
            }
            assetURL = url
            let digest = (asset["digest"] as? String)?.replacingOccurrences(of: "sha256:", with: "")
            assetDigest = (digest?.isEmpty == false) ? digest : nil
            Self.logger.info("update available: \(version, privacy: .public)")
            phase = .available(version, notes.isEmpty ? L("No release notes.") : notes)
        } catch {
            Self.logger.error("update check failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Installing

    func install() async {
        guard !busy, assetURL != nil else { return }
        busy = true
        defer {
            busy = false
            download = nil
            lastProgressAt = nil
        }
        do {
            guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
                throw UpdaterError.message(L("Updating works only from the Applications folder."))
            }
            phase = .working(L("Downloading the update…"))
            let dmgURL = try await downloadVerified()

            Self.logger.info("installing update")
            phase = .working(L("Installing the update…"))
            try Self.launchInstaller(dmg: dmgURL)
            // A presented SwiftUI sheet can veto termination, which leaves the
            // swap script waiting until its timeout. Close the sheet first.
            sheetPresented = false
            // The script waits for this process to exit, then swaps the bundle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
                // Hard watchdog: if termination is vetoed anyway, exit so the
                // detached installer can still replace the bundle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    exit(0)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Downloads the DMG into a temporary file and verifies its SHA256.
    private func downloadVerified() async throws -> URL {
        let dmgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MelonTools-update-\(UUID().uuidString).dmg")
        do {
            try await downloadTo(dmgURL)
            let expected = await expectedDigest()
            let actual = try Self.sha256Hex(of: dmgURL)
            guard let expected, actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw UpdaterError.message(L("SHA256 check failed - the download was refused."))
            }
            return dmgURL
        } catch {
            try? FileManager.default.removeItem(at: dmgURL)
            throw error
        }
    }

    /// Direct route first, proxy only when the CDN is unreachable that way.
    private func downloadTo(_ destination: URL) async throws {
        guard let assetURL else {
            throw UpdaterError.message(L("The update download failed."))
        }
        if let route = try? await Self.probe(assetURL, configuration: NetworkProxy.directConfiguration()) {
            do {
                try await Self.fetch(route, to: destination, progress: progressSink())
                return
            } catch {
                Self.logger.error("direct update download failed: \(error.localizedDescription, privacy: .public)")
                guard NetworkProxy.activeURL() != nil else { throw error }
            }
        }
        let route = try await Self.probe(assetURL, configuration: NetworkProxy.externalConfiguration())
        try await Self.fetch(route, to: destination, progress: progressSink())
    }

    /// Publishes download progress on the main actor, throttled to five
    /// updates per second so hundreds of delegate callbacks stay cheap.
    private func progressSink() -> @Sendable (Int64, Int64) -> Void {
        let started = Date()
        return { [weak self] received, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                if let last = self.lastProgressAt,
                   now.timeIntervalSince(last) < 0.2,
                   received < total {
                    return
                }
                self.lastProgressAt = now
                let elapsed = max(0.001, now.timeIntervalSince(started))
                self.download = UpdateDownloadProgress(
                    received: received,
                    total: total,
                    bytesPerSecond: Double(received) / elapsed
                )
            }
        }
    }

    /// Release digest, or the first token of the asset's `.sha256` sibling.
    private func expectedDigest() async -> String? {
        if let assetDigest { return assetDigest }
        guard let assetURL,
              let shaURL = URL(string: assetURL.absoluteString + ".sha256"),
              Self.isAllowed(shaURL) else { return nil }
        guard let (data, response) = try? await NetworkProxy.session().data(from: shaURL),
              let finalURL = response.url, Self.isAllowed(finalURL) else { return nil }
        return Self.parseSha256File(String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Chunked download

    /// One route to the asset: its size and the session configuration that
    /// reached it.
    struct Route {
        let url: URL
        let total: Int64
        let configuration: URLSessionConfiguration
    }

    /// Asks the asset for its size. HEAD is enough on GitHub; the one-byte
    /// range is a fallback for CDNs that omit `Content-Length` on HEAD.
    nonisolated static func probe(_ assetURL: URL, configuration: URLSessionConfiguration) async throws -> Route {
        var head = URLRequest(url: assetURL)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 30
        let (_, headResponse) = try await URLSession(configuration: configuration).data(for: head)
        if let http = headResponse as? HTTPURLResponse,
           http.statusCode == 200,
           let finalURL = headResponse.url,
           isAllowed(finalURL),
           let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }),
           length > 0 {
            return Route(url: assetURL, total: length, configuration: configuration)
        }

        var range = URLRequest(url: assetURL)
        range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        range.timeoutInterval = 30
        let (_, rangeResponse) = try await URLSession(configuration: configuration).data(for: range)
        guard let http = rangeResponse as? HTTPURLResponse,
              http.statusCode == 206,
              let finalURL = rangeResponse.url,
              isAllowed(finalURL),
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let total = contentRange.split(separator: "/").last.flatMap({ Int64($0) }),
              total > 0 else {
            throw UpdaterError.message(L("The update download failed."))
        }
        return Route(url: assetURL, total: total, configuration: configuration)
    }

    /// Downloads the asset in four parallel ranges. GitHub throttles a single
    /// connection, so four ranges are about three times faster in practice.
    nonisolated static func fetch(
        _ route: Route,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let partsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MelonTools-parts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: partsDirectory) }

        let meter = ProgressMeter(total: route.total, emit: progress)
        let count = route.total >= 8 * 1024 * 1024 ? 4 : 1
        let partSize = route.total / Int64(count)
        var parts: [URL] = []
        for index in 0..<count {
            parts.append(partsDirectory.appendingPathComponent("part-\(index)"))
        }

        if count == 1 {
            try await downloadRange(route: route, start: 0, end: route.total - 1, to: parts[0], meter: meter)
        } else {
            let last = count - 1
            async let first: Void = downloadRange(route: route, start: 0, end: partSize - 1, to: parts[0], meter: meter)
            async let second: Void = downloadRange(route: route, start: partSize, end: partSize * 2 - 1, to: parts[1], meter: meter)
            async let third: Void = downloadRange(route: route, start: partSize * 2, end: partSize * 3 - 1, to: parts[2], meter: meter)
            async let fourth: Void = downloadRange(route: route, start: partSize * 3, end: route.total - 1, to: parts[last], meter: meter)
            _ = try await (first, second, third, fourth)
        }

        try assemble(parts, total: route.total, into: destination)
    }

    nonisolated static func downloadRange(
        route: Route,
        start: Int64,
        end: Int64,
        to destination: URL,
        meter: ProgressMeter
    ) async throws {
        var request = URLRequest(url: route.url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 60
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let download = RangeDownload(
                destination: destination,
                expectedBytes: end - start + 1,
                onBytes: { meter.add($0) },
                onDone: { continuation.resume(with: $0) }
            )
            download.start(request, configuration: route.configuration)
        }
    }

    /// Joins the range files in order and checks the final size.
    nonisolated static func assemble(_ parts: [URL], total: Int64, into destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw UpdaterError.message(L("The update download failed."))
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var written: Int64 = 0
        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
        }
        guard written == total else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdaterError.message(L("The update download failed."))
        }
    }

    private static func launchInstaller(dmg: URL) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("melontools-update-\(UUID().uuidString).sh")
        let script = installerScript(
            appPath: Bundle.main.bundleURL.path,
            dmgPath: dmg.path,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// The detached swap script. Pure so tests can assert the rollback
    /// contract without running an installer.
    nonisolated static func installerScript(appPath: String, dmgPath: String, pid: Int32) -> String {
        """
        #!/bin/bash
        # Melon Tools self-update: replace the running bundle after it exits.
        # The log lives in the user's Logs folder (0600): the update script runs
        # as the user, and /tmp is world-readable and periodically purged.
        umask 077
        LOG_DIR="$HOME/Library/Logs/MelonTools"
        mkdir -p "$LOG_DIR"
        LOG="$LOG_DIR/update.log"
        : >> "$LOG"
        chmod 0600 "$LOG" 2>/dev/null || true
        exec >> "$LOG" 2>&1
        APP="\(appPath)"
        DMG="\(dmgPath)"
        PID=\(pid)
        MNT="$(mktemp -d /tmp/melontools-dmg.XXXXXX)"
        for _ in $(seq 1 15); do
          kill -0 "$PID" 2>/dev/null || break
          sleep 1
        done
        # A hung terminate must not end with the bundle swapped under a live
        # process: force it down first, and give up only if signals fail.
        if kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID" 2>/dev/null; sleep 2; fi
        if kill -0 "$PID" 2>/dev/null; then kill -KILL "$PID" 2>/dev/null; sleep 1; fi
        if kill -0 "$PID" 2>/dev/null; then exit 1; fi
        hdiutil attach -nobrowse -noverify -mountpoint "$MNT" "$DMG" || exit 1
        SRC="$(/bin/ls -d "$MNT"/*.app | head -1)"
        if [ ! -d "$SRC" ]; then hdiutil detach "$MNT" >/dev/null 2>&1; exit 1; fi
        rm -rf "$APP.melon-old"
        mv "$APP" "$APP.melon-old" || exit 1
        if ! ditto "$SRC" "$APP"; then
          rm -rf "$APP"
          if mv "$APP.melon-old" "$APP"; then open "$APP"; fi
          hdiutil detach "$MNT" >/dev/null 2>&1 || true
          rm -rf "$MNT" "$DMG"
          exit 1
        fi
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
        hdiutil detach "$MNT" >/dev/null 2>&1 || true
        open "$APP"
        # A broken update must not leave the user without a working app. Keep
        # the old bundle until the new process is actually visible, then roll
        # back if it never starts (bad build, quarantine, missing dylib).
        LAUNCHED=0
        for _ in $(seq 1 15); do
          if /usr/bin/pgrep -f "$APP/Contents/MacOS/MelonTools" >/dev/null 2>&1; then
            LAUNCHED=1
            break
          fi
          sleep 1
        done
        if [ "$LAUNCHED" -ne 1 ]; then
          echo "The new bundle did not start; restoring the previous one."
          rm -rf "$APP.melon-failed"
          if mv "$APP" "$APP.melon-failed" 2>/dev/null; then :; else rm -rf "$APP"; fi
          if mv "$APP.melon-old" "$APP"; then open "$APP"; fi
          rm -rf "$APP.melon-failed" "$MNT" "$DMG"
          rm -- "$0"
          exit 1
        fi
        rm -rf "$APP.melon-old" "$MNT" "$DMG"
        rm -- "$0"
        """
    }
}

/// Downloads one byte range into `destination` and reports the bytes written.
/// Each range owns its session so four ranges run independently; the delegate
/// callback that finishes the continuation is guarded against double resume.
private final class RangeDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let onBytes: @Sendable (Int64) -> Void
    private let onDone: @Sendable (Result<Void, Error>) -> Void

    private let lock = NSLock()
    private var session: URLSession?
    private var finished = false

    init(
        destination: URL,
        expectedBytes: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void,
        onDone: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.onBytes = onBytes
        self.onDone = onDone
    }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: request).resume()
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        session?.invalidateAndCancel()
        if case .failure = result {
            try? FileManager.default.removeItem(at: destination)
        }
        onDone(result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onBytes(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let http = downloadTask.response as? HTTPURLResponse,
              http.statusCode == 206,
              let finalURL = http.url,
              UpdaterStore.isAllowed(finalURL) else {
            finish(.failure(UpdaterStore.UpdaterError.message(L("The update download failed."))))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            guard size == expectedBytes else {
                throw UpdaterStore.UpdaterError.message(L("The update download failed."))
            }
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }
}

/// Sums bytes from all ranges and forwards at most five samples per second.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let emit: @Sendable (Int64, Int64) -> Void
    private var received: Int64 = 0
    private var lastEmit = Date.distantPast

    init(total: Int64, emit: @escaping @Sendable (Int64, Int64) -> Void) {
        self.total = total
        self.emit = emit
    }

    func add(_ bytes: Int64) {
        lock.lock()
        received += bytes
        let value = min(received, total)
        let now = Date()
        let shouldEmit = now.timeIntervalSince(lastEmit) >= 0.2 || value >= total
        if shouldEmit {
            lastEmit = now
        }
        lock.unlock()
        if shouldEmit {
            emit(value, total)
        }
    }
}
