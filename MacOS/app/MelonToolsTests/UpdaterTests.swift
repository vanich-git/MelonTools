import XCTest
@testable import MelonTools

/// The updater's pure logic: numeric version comparison, the URL allowlist
/// and the `.sha256` sidecar parser. Network and file operations stay
/// untested here on purpose.
final class UpdaterTests: XCTestCase {
    func testNumericallyNewerVersions() {
        XCTAssertTrue(UpdaterStore.Version.isNewer("1.4.10", than: "1.4.9"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("1.4.9", than: "1.4.10"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("1.5", than: "1.4.9"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("2.0.0", than: "1.99.99"))
    }

    func testEqualAndPaddedVersionsAreNotNewer() {
        XCTAssertFalse(UpdaterStore.Version.isNewer("1.4.7", than: "1.4.7"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("1.4", than: "1.4.0"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("1.4.0", than: "1.4"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("1.4.1", than: "1.4"))
    }

    /// Released builds carry a `-rc.N` suffix, so precedence has to follow
    /// SemVer: a final release outranks its own pre-releases.
    func testPrereleasesRankBelowTheirFinalRelease() {
        XCTAssertTrue(UpdaterStore.Version.isNewer("6.0.0", than: "6.0.0-rc.1"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("6.0.0-rc.1", than: "6.0.0"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("6.0.0-rc.2", than: "6.0.0-rc.1"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("6.0.0-rc.10", than: "6.0.0-rc.9"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("6.0.0-rc.11", than: "6.0.0-rc.10"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("6.0.0-rc.1", than: "6.0.0-rc.1"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("6.0.1", than: "6.0.0-rc.1"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("5.5.7", than: "6.0.0-rc.1"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("6.0.0", than: "6.0.0-beta.2"))
        XCTAssertTrue(UpdaterStore.Version.isNewer("6.0.0-beta.2", than: "6.0.0-alpha.10"))
        XCTAssertFalse(UpdaterStore.Version.isNewer("6.0.0+build.9", than: "6.0.0"))
    }

    func testOnlyGitHubHostsOverHTTPSAreAllowed() {
        XCTAssertTrue(UpdaterStore.isAllowed(URL(string: "https://api.github.com/repos/x/y/releases/latest")!))
        XCTAssertTrue(UpdaterStore.isAllowed(URL(string: "https://github.com/vanich-git/MelonTools/releases/download/v1/x.dmg")!))
        XCTAssertTrue(UpdaterStore.isAllowed(URL(string: "https://objects.githubusercontent.com/blob")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "http://github.com/x")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "https://evil.example.com/x")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "https://github.com.evil.example.com/x")!))
    }

    func testReleaseAssetCDNHostIsAllowed() {
        XCTAssertTrue(UpdaterStore.isAllowed(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123/asset.dmg")!))
    }

    func testReleaseAssetCDNLookalikesAndHTTPAreRejected() {
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "https://release-assets.githubusercontent.com.evil.example/x")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "https://evil-release-assets.githubusercontent.com/x")!))
        XCTAssertFalse(UpdaterStore.isAllowed(URL(string: "http://release-assets.githubusercontent.com/x")!))
    }

    func testSha256SidecarParsing() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(UpdaterStore.parseSha256File("\(hash)  MelonTools-1.4.8.dmg\n"), hash)
        XCTAssertEqual(UpdaterStore.parseSha256File("\(hash)\n"), hash)
        XCTAssertNil(UpdaterStore.parseSha256File("not-a-hash file.dmg"))
        XCTAssertNil(UpdaterStore.parseSha256File(""))
        XCTAssertNil(UpdaterStore.parseSha256File(String(repeating: "f", count: 63)))
    }

    func testPeriodicTimerChecksHourly() {
        XCTAssertEqual(UpdaterStore.periodicCheckInterval, 3600)
        XCTAssertEqual(UpdaterStore.automaticCheckThrottle, 3600)
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(UpdaterStore.shouldCheckAutomatically(lastCheck: now.addingTimeInterval(-30 * 60), now: now))
        XCTAssertFalse(UpdaterStore.shouldCheckAutomatically(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdaterStore.shouldCheckAutomatically(lastCheck: now.addingTimeInterval(-3660), now: now))
        XCTAssertTrue(UpdaterStore.shouldCheckAutomatically(lastCheck: .distantPast, now: now))
    }

    func testInstallerScriptKeepsTheOldBundleUntilTheNewAppRuns() throws {
        let script = UpdaterStore.installerScript(
            appPath: "/Applications/Melon Tools.app",
            dmgPath: "/tmp/MelonTools-1.7.0.dmg",
            pid: 4242
        )
        XCTAssertTrue(script.contains("PID=4242"))
        XCTAssertTrue(script.contains("APP=\"/Applications/Melon Tools.app\""))
        XCTAssertTrue(script.contains("/usr/bin/pgrep -f \"$APP/Contents/MacOS/MelonTools\""))

        let probe = try XCTUnwrap(script.range(of: "LAUNCHED=0"))
        let pgrep = try XCTUnwrap(script.range(of: "/usr/bin/pgrep -f"))
        let rollback = try XCTUnwrap(script.range(of: "The new bundle did not start; restoring the previous one."))
        let restore = try XCTUnwrap(script.range(of: "mv \"$APP.melon-old\" \"$APP\"", options: [], range: rollback.lowerBound..<script.endIndex))
        let successCleanup = try XCTUnwrap(script.range(of: "rm -rf \"$APP.melon-old\" \"$MNT\" \"$DMG\""))
        XCTAssertLessThan(probe.lowerBound, pgrep.lowerBound)
        XCTAssertLessThan(pgrep.lowerBound, rollback.lowerBound)
        XCTAssertLessThan(rollback.lowerBound, restore.lowerBound)
        XCTAssertLessThan(pgrep.lowerBound, successCleanup.lowerBound)
    }

    func testInstallerScriptIsSyntacticallyValid() throws {
        let script = UpdaterStore.installerScript(
            appPath: "/Applications/Melon Tools.app",
            dmgPath: "/tmp/MelonTools-1.7.0.dmg",
            pid: 4242
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdaterScriptTests-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: url) }
        try script.write(to: url, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Chunked download

    func testProgressFractionIsClampedToTheDownload() {
        XCTAssertEqual(UpdateDownloadProgress(received: 50, total: 100, bytesPerSecond: 0).fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(UpdateDownloadProgress(received: 150, total: 100, bytesPerSecond: 0).fraction, 1)
        XCTAssertEqual(UpdateDownloadProgress(received: 10, total: 0, bytesPerSecond: 0).fraction, 0)
    }

    func testAssembleJoinsPartsInOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-assemble-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parts = (0..<3).map { directory.appendingPathComponent("part-\($0)") }
        try Data("alpha".utf8).write(to: parts[0])
        try Data("beta".utf8).write(to: parts[1])
        try Data("gamma".utf8).write(to: parts[2])
        let output = directory.appendingPathComponent("joined.bin")

        try UpdaterStore.assemble(parts, total: 14, into: output)

        XCTAssertEqual(try Data(contentsOf: output), Data("alphabetagamma".utf8))
    }

    func testAssembleRejectsAShortFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-assemble-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let part = directory.appendingPathComponent("part-0")
        try Data("short".utf8).write(to: part)
        let output = directory.appendingPathComponent("joined.bin")

        XCTAssertThrowsError(try UpdaterStore.assemble([part], total: 99, into: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// Opt-in network test: downloads the published 6.0.0 DMG through the real
    /// four-range path and checks its digest. Off by default so CI stays fast;
    /// run with `MT_UPDATE_NETWORK_TEST=1 xcodebuild test ...`.
    func testChunkedDownloadOfPublishedAsset() async throws {
        guard ProcessInfo.processInfo.environment["MT_UPDATE_NETWORK_TEST"] == "1" else {
            throw XCTSkip("set MT_UPDATE_NETWORK_TEST=1 to download the release asset")
        }
        let url = URL(string: "https://github.com/vanich-git/MelonTools/releases/download/v6.0.0/MelonTools-6.0.0.dmg")!
        let route = try await UpdaterStore.probe(url, configuration: NetworkProxy.directConfiguration())
        XCTAssertEqual(route.total, 105_559_658)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-update-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await UpdaterStore.fetch(route, to: destination) { _, _ in }

        XCTAssertEqual(
            try UpdaterStore.sha256Hex(of: destination),
            "956f2105e974302383e66246dd67a8e57a004f1b8d49354a5733a61961d6dd77"
        )
    }
}

/// The secrets writer must never leave a half-written or world-readable file:
/// an interrupted write keeps the previous contents, and every write is 0600.
final class SecureFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    func testWriteCreatesFileWithContentsAnd0600() throws {
        let url = directory.appendingPathComponent("auth.json")
        let payload = Data(#"{"token":"secret"}"#.utf8)

        try SecureFile.write(payload, to: url)

        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(try permissions(of: url) & 0o777, 0o600)
    }

    func testOverwriteReplacesContentsAndKeepsMode() throws {
        let url = directory.appendingPathComponent("auth.json")
        try SecureFile.write("first", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try SecureFile.write("second payload", to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second payload")
        XCTAssertEqual(try permissions(of: url) & 0o777, 0o600)
    }

    func testWriteLeavesNoTemporarySibling() throws {
        let url = directory.appendingPathComponent("auth.json")

        try SecureFile.write("payload", to: url)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["auth.json"])
    }

    func testFailedWriteKeepsThePreviousFile() throws {
        let url = directory.appendingPathComponent("auth.json")
        try SecureFile.write("stable", to: url)
        // A directory cannot be replaced by rename(2), so the write must throw
        // and the original file must survive untouched.
        let blocked = directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SecureFile.write("replacement", to: blocked))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "stable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".blocked.") }
        XCTAssertTrue(leftovers.isEmpty, "a failed write must remove its temp file")
    }
}
