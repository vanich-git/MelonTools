import XCTest
@testable import MelonTools

/// A routing group is an alias. The engine maps the alias to whichever member
/// it picks, so the members do not have to be the same model: one provider can
/// serve `deepseek-v4.1-flash` while another serves `deepseek-v4.1-flash-free`.
/// The only rule the store enforces is that one provider does not get two rows
/// for the very same model, because that would double its share of the traffic
/// without giving it anything to serve it with.
final class RoutingGroupModelTests: XCTestCase {

    private func member(_ source: String, _ model: String) -> RoutingGroupMember {
        RoutingGroupMember(sourceID: source, modelID: model)
    }

    // MARK: - Group membership

    func testTheSameModelOnTwoProvidersIsKeptTwice() {
        let members = [
            member("dotai", "deepseek-v4.1-flash"),
            member("astraapi", "deepseek-v4.1-flash"),
        ]
        let unique = RoutingGroupsStore.uniqueMembers(members)
        XCTAssertEqual(unique.count, 2, "one row per provider")
        XCTAssertEqual(unique.map(\.sourceID), ["dotai", "astraapi"])
    }

    func testTwoRowsOfOneProviderAndModelCollapseToOne() {
        let members = [
            member("dotai", "deepseek-v4.1-flash"),
            member("dotai", "deepseek-v4.1-flash"),
            member("astraapi", "deepseek-v4.1-flash"),
        ]
        let unique = RoutingGroupsStore.uniqueMembers(members)
        XCTAssertEqual(unique.count, 2, "a repeated row is not a second route")
        XCTAssertEqual(unique.map(\.sourceID), ["dotai", "astraapi"])
    }

    /// The live group mixes these on purpose: the free tier and the paid tier
    /// of the same family are different models and both are valid members.
    func testDifferentModelsInOneGroupAreAllKept() {
        let members = [
            member("million-deepseek", "deepseek-v4.1-flash-free"),
            member("dotai", "deepseek-v4.1-flash"),
            member("astraapi", "deepseek-v4.1-flash"),
            member("iishko", "qwen4-max"),
        ]
        let unique = RoutingGroupsStore.uniqueMembers(members)
        XCTAssertEqual(unique.count, 4, "every distinct row survives")
    }

    /// Two ids that only look alike are two rows, not one: the user added both
    /// deliberately and folding them together would drop a member silently.
    func testIdsThatDifferOnlyInSpellingAreBothKept() {
        let members = [
            member("dotai", "deepseek-v4.1-flash"),
            member("dotai", "deepseek-v4-1-flash"),
        ]
        let unique = RoutingGroupsStore.uniqueMembers(members)
        XCTAssertEqual(unique.count, 2)
    }

    func testUniqueMembersKeepsTheOrderTheUserSet() {
        let members = [
            member("astraapi", "deepseek-v4.1-flash"),
            member("bashapi", "deepseek-v4.1-flash"),
            member("dotai", "deepseek-v4.1-flash"),
        ]
        XCTAssertEqual(
            RoutingGroupsStore.uniqueMembers(members).map(\.sourceID),
            ["astraapi", "bashapi", "dotai"]
        )
    }

    // MARK: - Alias generation

    private func source(_ id: String, kind: ModelSource.Kind, enabled: Bool = true, models: [SourceModel]) -> ModelSource {
        ModelSource(
            id: id,
            kind: kind,
            title: id,
            baseURL: "http://127.0.0.1:18317/v1",
            apiKey: "test",
            enabled: enabled,
            models: models
        )
    }

    private func model(_ id: String, enabled: Bool = true, anthropicOnly: Bool? = nil) -> SourceModel {
        SourceModel(
            id: id,
            display: id,
            enabled: enabled,
            alias: id,
            anthropicOnly: anthropicOnly
        )
    }

    private func customSource(
        id: String,
        apiProtocol: ModelSource.APIProtocol,
        models: [SourceModel]
    ) -> ModelSource {
        ModelSource(
            id: id,
            kind: .custom,
            title: id,
            baseURL: "http://127.0.0.1:18317/v1",
            apiKey: "test",
            enabled: true,
            models: models,
            apiProtocol: apiProtocol
        )
    }

    func testDisabledModelIsStillEnabledThroughGroupAlias() {
        let sources = [source("dotai", kind: .openCode, models: [model("m1", enabled: false)])]
        let group = RoutingGroup(alias: "alias", members: [member("dotai", "m1")])
        let aliases = RoutingGroupsStore.aliasModels(groups: [group], sources: sources)
        let alias = try? XCTUnwrap(aliases["dotai"]?.first)
        XCTAssertEqual(alias?.alias, "alias")
        XCTAssertEqual(alias?.enabled, true)
    }

    func testGroupAliasesDeduplicateOnlyIdenticalModelAliasPairs() {
        let sources = [source("dotai", kind: .openCode, models: [model("m1"), model("m2")])]
        let groups = [RoutingGroup(alias: "m1", members: [member("dotai", "m1"), member("dotai", "m2")])]
        let aliases = RoutingGroupsStore.aliasModels(groups: groups, sources: sources)
        let yaml = ModelSourcesStore.gatewayYAML(sources: sources, groupAliases: aliases)
        XCTAssertEqual(yaml.components(separatedBy: "- name: \"m1\"").count - 1, 1)
        XCTAssertEqual(yaml.components(separatedBy: "alias: \"m1\"").count - 1, 2)
    }

    func testCommandCodeAnthropicOnlyModelCanCarryGroupAlias() {
        let sources = [source("cc", kind: .commandCode, models: [model("claude-sonnet-5-5", anthropicOnly: true)])]
        let group = RoutingGroup(alias: "alias", members: [member("cc", "claude-sonnet-5-5")])
        let aliases = RoutingGroupsStore.aliasModels(groups: [group], sources: sources)
        XCTAssertEqual(aliases["cc"]?.map(\.alias), ["alias"])
    }

    func testCustomAnthropicSourceCanCarryGroupAlias() {
        let sources = [
            customSource(
                id: "anthropic-alias",
                apiProtocol: .anthropic,
                models: [model("claude-sonnet-5-5", anthropicOnly: true)]
            )
        ]
        let group = RoutingGroup(alias: "alias", members: [member("anthropic-alias", "claude-sonnet-5-5")])
        let aliases = RoutingGroupsStore.aliasModels(groups: [group], sources: sources)
        XCTAssertEqual(aliases["anthropic-alias"]?.map(\.alias), ["alias"])
    }

    func testNonPublishableMembersAreReported() {
        let sources = [
            source("plugin", kind: .plugin, models: [model("p1")]),
            source("oauth", kind: .antigravity, models: [model("a1")]),
            ModelSource(
                id: "no-key",
                kind: .custom,
                title: "no-key",
                baseURL: "http://127.0.0.1:18317/v1",
                apiKey: "",
                enabled: true,
                models: [model("m1")]
            ),
        ]
        for member in [member("plugin", "p1"), member("oauth", "a1"), member("no-key", "m1")] {
            XCTAssertEqual(
                RoutingGroupsStore.memberStatus(member, sources: sources),
                .notPublishable,
                "\(member.sourceID) cannot write an api-keys block"
            )
        }
        XCTAssertTrue(RoutingGroupsStore.aliasModels(groups: [
            RoutingGroup(alias: "alias", members: [member("plugin", "p1")])
        ], sources: sources).isEmpty)
        XCTAssertEqual(
            RoutingGroupsStore.memberStatus(
                member("plugin", "p1"),
                sources: [source("plugin", kind: .plugin, models: [model("p1", enabled: false)])]
            ),
            .notPublishable
        )
    }

    func testSameModelInTwoGroupsGetsBothAliases() {
        let sources = [source("dotai", kind: .openCode, models: [model("m1")])]
        let groups = [
            RoutingGroup(alias: "first", members: [member("dotai", "m1")]),
            RoutingGroup(alias: "second", members: [member("dotai", "m1")]),
        ]
        let aliases = RoutingGroupsStore.aliasModels(groups: groups, sources: sources)
        XCTAssertEqual(aliases["dotai"]?.map(\.alias), ["first", "second"])
    }

    func testMissingAndDisabledSourcesReportStatus() {
        let sources = [
            source("on", kind: .openCode, models: [model("m1")]),
            source("off", kind: .openCode, enabled: false, models: [model("m2")]),
        ]
        XCTAssertEqual(
            RoutingGroupsStore.memberStatus(member("on", "m1"), sources: sources),
            .active
        )
        XCTAssertEqual(
            RoutingGroupsStore.memberStatus(member("on", "gone"), sources: sources),
            .modelMissing
        )
        XCTAssertEqual(
            RoutingGroupsStore.memberStatus(member("off", "m2"), sources: sources),
            .sourceDisabled
        )
        XCTAssertEqual(
            RoutingGroupsStore.memberStatus(member("missing", "m1"), sources: sources),
            .sourceMissing
        )
    }

    func testWindowsJSONIsDecodedAndReencodedInSwiftFormat() throws {
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","alias":"shared","note":"","enabled":true,"members":[{"sourceId":"dotai","modelId":"m1"}]}]
        """
        let groups = try JSONDecoder().decode([RoutingGroup].self, from: Data(json.utf8))
        let group = try XCTUnwrap(groups.first)
        let member = try XCTUnwrap(group.members.first)
        XCTAssertEqual(group.id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(member.sourceID, "dotai")
        XCTAssertEqual(member.modelID, "m1")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(groups)) as? [[String: Any]]
        let encodedMembers = try XCTUnwrap(encoded?.first?["members"] as? [[String: Any]])
        let encodedMember = try XCTUnwrap(encodedMembers.first)
        XCTAssertNotNil(encoded?.first?["createdAt"])
        XCTAssertNotNil(encodedMember["id"])
        XCTAssertNotNil(encodedMember["sourceID"])
        XCTAssertNotNil(encodedMember["modelID"])
        XCTAssertNil(encodedMember["sourceId"])
        XCTAssertNil(encodedMember["modelId"])
    }

    @MainActor
    func testCorruptGroupsAreNotOverwritten() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent("routing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("routing-groups.json")
        let damaged = Data("{broken".utf8)
        try damaged.write(to: file)
        let store = RoutingGroupsStore.testStore(fileURL: file)
        XCTAssertFalse(store.isSafeToWrite)
        XCTAssertNotNil(store.add(alias: "group", members: [member("source", "model")]))
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    @MainActor
    func testUnreadableFileBlocksWritesAndRetryRecovers() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent("routing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("routing-groups.json")
        try Data("[]".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let store = RoutingGroupsStore.testStore(fileURL: file)
        XCTAssertFalse(store.isSafeToWrite, "unreadable file must fail closed")
        XCTAssertNotNil(store.add(alias: "blocked", members: [member("dotai", "m1")]))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let group = RoutingGroup(alias: "recovered", members: [member("dotai", "m1")])
        try encoder.encode([group]).write(to: file)

        store.loadIfNeeded()
        XCTAssertTrue(store.isSafeToWrite)
        XCTAssertEqual(store.groups.map(\.alias), ["recovered"])
    }

    @MainActor
    func testUnreadableParentDirectoryBlocksWrites() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent("routing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("routing-groups.json")
        try Data("[]".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)

        let store = RoutingGroupsStore.testStore(fileURL: file)
        XCTAssertFalse(store.isSafeToWrite, "an inaccessible parent must not look like a missing file")
        XCTAssertNotNil(store.add(alias: "blocked", members: [member("dotai", "m1")]))
        XCTAssertTrue(store.groups.isEmpty)
    }

    @MainActor
    func testSaveFailureRollsBackMemory() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent("routing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let store = RoutingGroupsStore.testStore(fileURL: blocker.appendingPathComponent("routing-groups.json"))
        XCTAssertNotNil(store.add(alias: "group", members: [member("source", "model")]))
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testEmptyMemberListStaysEmpty() {
        XCTAssertTrue(RoutingGroupsStore.uniqueMembers([]).isEmpty)
    }
}
