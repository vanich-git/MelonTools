import XCTest
@testable import MelonTools

/// The Codex app resolves its ChatGPT account from `~/.codex/auth.json`.
/// A file written without `tokens.account_id`/`auth_mode` (JSONEncoder drops
/// nil optionals) made Codex log “waiting for a ChatGPT account id” and block
/// chatting with “failed to load workspace settings” — these tests pin the
/// full file shape.
final class CodexAuthFileTests: XCTestCase {

    private static func jwt(accountId: String) -> String {
        let payload: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": accountId]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(b64).signature"
    }

    private func decoded(_ auth: CodexAuthFile) throws -> [String: Any] {
        let data = try auth.encoded()
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    func testUnreadableVaultOriginalSurvivesForTheNextLaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-failure-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("accounts.json")
        let bytes = Data("unreadable-vault".utf8)
        try bytes.write(to: original)
        let copy = CodexStore.preserveUnreadableVault(at: original)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        // A second failed launch must still encounter the same bad file, not
        // classify the absent file as a fresh empty pool and prune auths.
        CodexStore.preserveUnreadableVault(at: original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testAuthFileCarriesModeAndAccountID() throws {
        var tokens = CodexTokens(id_token: Self.jwt(accountId: "claim-id"))
        tokens.access_token = "access-token"
        tokens.refresh_token = "refresh-token"
        var account = CodexAccount(tokens: tokens)
        account.accountId = "acct-123"

        let json = try decoded(CodexAuthFile.make(from: account))

        XCTAssertEqual(json["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(json.keys.contains("OPENAI_API_KEY"), "the key must be present (null), like the app writes it")
        let tokensJSON = try XCTUnwrap(json["tokens"] as? [String: Any])
        XCTAssertEqual(tokensJSON["account_id"] as? String, "acct-123")
        XCTAssertEqual(tokensJSON["access_token"] as? String, "access-token")
        XCTAssertEqual(tokensJSON["refresh_token"] as? String, "refresh-token")
    }

    func testAuthFileFallsBackToTokenClaim() throws {
        let account = CodexAccount(tokens: CodexTokens(id_token: Self.jwt(accountId: "from-claim")))

        let json = try decoded(CodexAuthFile.make(from: account))

        let tokensJSON = try XCTUnwrap(json["tokens"] as? [String: Any])
        XCTAssertEqual(tokensJSON["account_id"] as? String, "from-claim")
    }

    func testStoredTokensAccountIDWins() throws {
        var tokens = CodexTokens(id_token: Self.jwt(accountId: "claim-id"))
        tokens.account_id = "stored-id"
        var account = CodexAccount(tokens: tokens)
        account.accountId = "record-id"

        let json = try decoded(CodexAuthFile.make(from: account))

        let tokensJSON = try XCTUnwrap(json["tokens"] as? [String: Any])
        XCTAssertEqual(tokensJSON["account_id"] as? String, "stored-id")
    }

    // MARK: - Gateway mirror must not run on an untrusted vault (CORE-05)

    private func temporaryAuthDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A failed/newer vault load leaves `accounts` empty. Syncing that list
    /// with orphan pruning deletes every engine-owned auth file, including the
    /// freshest rotated refresh tokens the vault does not have.
    func testEmptySnapshotWithoutPruningKeepsGatewayAuthFiles() throws {
        let dir = try temporaryAuthDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let owned = dir.appendingPathComponent("codex-existing.json")
        let foreign = dir.appendingPathComponent("claude-existing.json")
        try Data("{\"type\":\"codex\"}".utf8).write(to: owned)
        try Data("{\"type\":\"claude\"}".utf8).write(to: foreign)

        try CodexGatewayService.syncAccounts(
            [],
            priorities: [:],
            authDir: dir,
            pruneOrphans: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))

        // The destructive default is exactly what the gate suppresses.
        try CodexGatewayService.syncAccounts(
            [],
            priorities: [:],
            authDir: dir,
            pruneOrphans: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: foreign.path),
            "only codex-*.json files are owned by the mirror"
        )
    }

    /// Suppressing the prune must not suppress the writes themselves: a loaded
    /// vault still has to reach the engine.
    func testNonPruningSyncStillWritesTheDesiredAccounts() throws {
        let dir = try temporaryAuthDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var tokens = CodexTokens()
        tokens.access_token = "at-live"
        tokens.refresh_token = "rt-live"
        let account = CodexAccount(tokens: tokens)

        try CodexGatewayService.syncAccounts(
            [account],
            priorities: [:],
            authDir: dir,
            pruneOrphans: false
        )

        let expected = dir.appendingPathComponent(CodexGatewayService.authFileName(for: account))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testOnlyASuccessfullyLoadedVaultAllowsDestructiveMirroring() {
        XCTAssertTrue(CodexStore.VaultLoadState.loaded.allowsDestructiveGatewaySync)
        XCTAssertFalse(CodexStore.VaultLoadState.failed.allowsDestructiveGatewaySync)
        XCTAssertFalse(CodexStore.VaultLoadState.readOnly.allowsDestructiveGatewaySync)
        XCTAssertFalse(CodexStore.VaultLoadState.notLoaded.allowsDestructiveGatewaySync)
    }
}

/// Instance Codex homes are keyed by UUID, not by display name: on a
/// case-insensitive APFS volume `Work` and `work` were one directory, so the
/// instances shared a login and deleting either wiped the other (CORE-04).
final class CodexInstanceHomesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-instances-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeLegacyHome(name: String, auth: String = "{\"token\":\"legacy\"}") throws -> URL {
        let home = root
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(auth.utf8).write(to: home.appendingPathComponent("auth.json"))
        return home
    }

    func testCaseCollidingNamesGetIndependentHomes() throws {
        let legacy = try makeLegacyHome(name: "work")
        var upper = CodexInstance(name: "Work", accountId: nil)
        upper.id = "11111111-1111-1111-1111-111111111111"
        var lower = CodexInstance(name: "work", accountId: nil)
        lower.id = "22222222-2222-2222-2222-222222222222"

        let notes = CodexInstanceHomes.migrate(root: root, instances: [upper, lower])

        let upperHome = CodexInstanceHomes.home(root: root, id: upper.id)
        let lowerHome = CodexInstanceHomes.home(root: root, id: lower.id)
        XCTAssertNotEqual(upperHome.path.lowercased(), lowerHome.path.lowercased())
        XCTAssertTrue(FileManager.default.fileExists(atPath: upperHome.appendingPathComponent("auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lowerHome.appendingPathComponent("auth.json").path))
        XCTAssertEqual(notes.count, 2)

        // The shared legacy folder stays untouched for recovery.
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("auth.json").path))
        let legacyAuth = try String(contentsOf: legacy.appendingPathComponent("auth.json"), encoding: .utf8)
        XCTAssertEqual(legacyAuth, "{\"token\":\"legacy\"}")
    }

    func testFailedSharedMigrationLeavesNoEmptyHomeAndCanRetry() throws {
        try XCTSkipIf(NSUserName() == "root", "root can read mode-000 files")
        let legacy = try makeLegacyHome(name: "work")
        let auth = legacy.appendingPathComponent("auth.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: auth.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path) }

        var upper = CodexInstance(name: "Work", accountId: nil)
        upper.id = "88888888-8888-8888-8888-888888888888"
        var lower = CodexInstance(name: "work", accountId: nil)
        lower.id = "99999999-9999-9999-9999-999999999999"

        let notes = CodexInstanceHomes.migrate(root: root, instances: [upper, lower])

        XCTAssertTrue(notes.isEmpty)
        for id in [upper.id, lower.id] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: CodexInstanceHomes.home(root: root, id: id).path
                ),
                "a failed copy must not leave a destination that blocks the next attempt"
            )
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        let retryNotes = CodexInstanceHomes.migrate(root: root, instances: [upper, lower])

        XCTAssertEqual(retryNotes.count, 2)
        for id in [upper.id, lower.id] {
            let copied = CodexInstanceHomes.home(root: root, id: id).appendingPathComponent("auth.json")
            let contents = try String(contentsOf: copied, encoding: .utf8)
            XCTAssertEqual(contents, "{\"token\":\"legacy\"}")
        }
    }

    func testSingleLegacyHomeMovesWithItsHistory() throws {
        let legacy = try makeLegacyHome(name: "Work")
        try Data("history\n".utf8).write(to: legacy.appendingPathComponent("history.jsonl"))
        var instance = CodexInstance(name: "Work", accountId: nil)
        instance.id = "33333333-3333-3333-3333-333333333333"

        let notes = CodexInstanceHomes.migrate(root: root, instances: [instance])

        let home = CodexInstanceHomes.home(root: root, id: instance.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("history.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "a unique legacy home is moved, not copied")
        XCTAssertEqual(notes.count, 1)
    }

    func testMigrationIsIdempotentAndNeverTouchesAnExistingUUIDHome() throws {
        _ = try makeLegacyHome(name: "Work")
        var instance = CodexInstance(name: "Work", accountId: nil)
        instance.id = "44444444-4444-4444-4444-444444444444"
        CodexInstanceHomes.migrate(root: root, instances: [instance])

        let home = CodexInstanceHomes.home(root: root, id: instance.id)
        try Data("marker".utf8).write(to: home.appendingPathComponent("marker.txt"))

        let notes = CodexInstanceHomes.migrate(root: root, instances: [instance])

        XCTAssertTrue(notes.isEmpty)
        let marker = try String(contentsOf: home.appendingPathComponent("marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, "marker")
    }

    func testDeleteTargetStaysInsideTheInstancesRoot() {
        let container = CodexInstanceHomes.ownedContainer(root: root, id: "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(container?.lastPathComponent, "55555555-5555-5555-5555-555555555555")
        XCTAssertNil(CodexInstanceHomes.ownedContainer(root: root, id: "../escape"))
        XCTAssertNil(CodexInstanceHomes.ownedContainer(root: root, id: "/tmp/elsewhere"))
        XCTAssertNil(CodexInstanceHomes.ownedContainer(root: root, id: "."))
    }

    func testRemovingOneInstanceLeavesOtherHomesAndTheLegacyFolder() throws {
        let legacy = try makeLegacyHome(name: "work")
        let first = root.appendingPathComponent("66666666-6666-6666-6666-666666666666", isDirectory: true)
        let second = root.appendingPathComponent("77777777-7777-7777-7777-777777777777", isDirectory: true)
        for container in [first, second] {
            try FileManager.default.createDirectory(
                at: container.appendingPathComponent("codex-home"),
                withIntermediateDirectories: true
            )
        }

        let owned = try XCTUnwrap(CodexInstanceHomes.ownedContainer(root: root, id: first.lastPathComponent))
        try FileManager.default.removeItem(at: owned)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
}
