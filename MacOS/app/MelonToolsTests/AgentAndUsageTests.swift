import XCTest
@testable import MelonTools

/// Usage aggregation, routing group aliases and agent config transformations.
/// Everything here is pure data in, data out: no file in the home directory is
/// touched by these tests.
@MainActor
final class AgentAndUsageTests: XCTestCase {

    // MARK: - Usage

    private func event(
        _ model: String,
        provider: String = "openrouter",
        input: Int = 100,
        output: Int = 50,
        status: Int = 200,
        at: Date = Date()
    ) -> UsageEvent {
        UsageEvent(
            at: at,
            model: model,
            provider: provider,
            auth: "key",
            input: input,
            output: output,
            mode: "stream",
            status: status
        )
    }

    private func price(_ prompt: Double, _ completion: Double) -> SourceModel {
        SourceModel(
            id: "upstream",
            display: "Upstream",
            contextLength: nil,
            enabled: true,
            alias: "upstream",
            promptPerToken: prompt,
            completionPerToken: completion
        )
    }

    func testCostUsesPromptAndCompletionPrices() {
        let model = price(0.000001, 0.000002)
        let cost = UsageHistory.cost(of: event("m", input: 1000, output: 500), price: model)
        XCTAssertEqual(cost ?? -1, 0.002, accuracy: 0.0000001)
        XCTAssertNil(UsageHistory.cost(of: event("m"), price: nil))
        let noPrices = SourceModel(
            id: "upstream",
            display: "Upstream",
            contextLength: nil,
            enabled: true,
            alias: "upstream",
            promptPerToken: nil,
            completionPerToken: nil
        )
        XCTAssertNil(UsageHistory.cost(of: event("m"), price: noPrices))
    }

    func testTotalsCountErrorsAndOnlyPricedCalls() {
        let events = [
            event("a", input: 10, output: 5),
            event("b", input: 20, output: 10, status: 500)
        ]
        let totals = UsageHistory.totals(events) { _ in 0.5 }
        XCTAssertEqual(totals.calls, 2)
        XCTAssertEqual(totals.errors, 1)
        XCTAssertEqual(totals.input, 30)
        XCTAssertEqual(totals.output, 15)
        XCTAssertEqual(totals.tokens, 45)
        XCTAssertEqual(totals.pricedCalls, 2)
        XCTAssertEqual(totals.cost, 1.0, accuracy: 0.0001)
        XCTAssertEqual(totals.errorRate, 0.5, accuracy: 0.0001)
    }

    func testDedupKeyIsStableAndDistinguishesStatus() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let first = event("m", input: 1, output: 2, status: 200, at: at)
        let same = event("m", input: 1, output: 2, status: 200, at: at)
        let failed = event("m", input: 1, output: 2, status: 500, at: at)
        XCTAssertEqual(first.id, same.id)
        XCTAssertNotEqual(first.id, failed.id)
    }

    func testWeekBarsFillEveryDay() {
        let now = Date()
        let bars = UsageHistory.bars(
            [event("m", at: now)],
            in: .week,
            now: now,
            price: { _ in nil }
        )
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars.last?.totals.calls, 1)
        XCTAssertEqual(bars.filter { $0.totals.calls > 0 }.count, 1)
    }

    func testTodayBarsAreHourly() {
        let bars = UsageHistory.bars(
            [event("m")],
            in: .today,
            price: { _ in nil }
        )
        XCTAssertEqual(bars.count, 24)
    }

    func testPeriodFilterDropsOlderEvents() {
        let now = Date()
        let old = event("old", at: now.addingTimeInterval(-60 * 60 * 24 * 10))
        let fresh = event("fresh", at: now)
        let scoped = UsageHistory.events([old, fresh], in: .week, now: now)
        XCTAssertEqual(scoped.map(\.model), ["fresh"])
        XCTAssertEqual(UsageHistory.events([old, fresh], in: .all, now: now).count, 2)
    }

    func testBreakdownSortsByTokensAndComputesShare() {
        let rows = UsageBreakdown.rows(
            from: [event("big", input: 1000, output: 0), event("small", input: 10, output: 0)],
            key: { $0.model },
            title: { $0 },
            cost: { _ in nil }
        )
        XCTAssertEqual(rows.map(\.id), ["big", "small"])
        XCTAssertEqual(rows.first?.share ?? 0, 1000.0 / 1010.0, accuracy: 0.0001)
    }

    // MARK: - Routing

    func testAliasNormalizationAndValidation() {
        XCTAssertEqual(RoutingGroupsStore.normalize(alias: "  Fast Model "), "fast-model")
        XCTAssertNil(RoutingGroupsStore.aliasProblem("fast-model", existing: []))
        XCTAssertNotNil(RoutingGroupsStore.aliasProblem("", existing: []))
        XCTAssertNotNil(RoutingGroupsStore.aliasProblem("Fast Model", existing: []))
        XCTAssertNotNil(RoutingGroupsStore.aliasProblem("fast", existing: ["fast"]))
        XCTAssertNotNil(RoutingGroupsStore.aliasProblem(String(repeating: "a", count: 65), existing: []))
    }

    func testAliasModelsSkipDisabledSourcesAndGroups() {
        let source = ModelSource(
            id: "custom-a",
            kind: .custom,
            title: "A",
            baseURL: "https://a.example.com/v1",
            apiKey: "sk-a",
            enabled: true,
            models: [
                SourceModel(id: "upstream-a", display: "A", contextLength: nil, enabled: true, alias: "upstream-a")
            ],
            apiProtocol: .openAIChat
        )
        var group = RoutingGroup(
            alias: "fast",
            enabled: true,
            members: [RoutingGroupMember(sourceID: "custom-a", modelID: "upstream-a")]
        )
        let aliases = RoutingGroupsStore.aliasModels(groups: [group], sources: [source])
        XCTAssertEqual(aliases["custom-a"]?.count, 1)
        XCTAssertEqual(aliases["custom-a"]?.first?.alias, "fast")
        XCTAssertEqual(aliases["custom-a"]?.first?.id, "upstream-a")

        group.enabled = false
        XCTAssertTrue(RoutingGroupsStore.aliasModels(groups: [group], sources: [source]).isEmpty)

        group.enabled = true
        var disabled = source
        disabled.enabled = false
        XCTAssertTrue(RoutingGroupsStore.aliasModels(groups: [group], sources: [disabled]).isEmpty)
    }

    func testGatewayYAMLAddsGroupAliasToProvider() {
        let source = ModelSource(
            id: "custom-a",
            kind: .custom,
            title: "A",
            baseURL: "https://a.example.com/v1",
            apiKey: "sk-a",
            enabled: true,
            models: [
                SourceModel(id: "upstream-a", display: "A", contextLength: nil, enabled: true, alias: "upstream-a")
            ],
            apiProtocol: .openAIChat
        )
        var aliasModel = source.models[0]
        aliasModel.alias = "fast"
        aliasModel.display = "fast"
        let yaml = ModelSourcesStore.gatewayYAML(
            sources: [source],
            groupAliases: ["custom-a": [aliasModel]]
        )
        XCTAssertTrue(yaml.contains("name: \"upstream-a\""))
        XCTAssertTrue(yaml.contains("alias: \"fast\""))
    }

    // MARK: - Agents

    private func adapterText(
        _ id: String,
        current: String = "",
        model: String,
        effort: String = ""
    ) throws -> String {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: id))
        let url = URL(fileURLWithPath: "/tmp/melon-test-\(id)")
        let edits = try AgentAdapters.edits(
            definition: definition,
            urls: [url],
            files: [url.path: current],
            context: AgentApplyContext(
                baseURL: "http://127.0.0.1:18317/v1",
                apiKey: "k",
                model: model,
                effort: effort
            )
        )
        return edits[0].text
    }


    func testClaudeJSONKeepsOtherKeysAndSetsEnv() throws {
        let input = """
        {
          "model": "opus",
          "env": {
            "EXISTING": "1"
          }
        }
        """
        let output = try adapterText("claude", current: input, model: "opus")
        let data = try XCTUnwrap(output.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opus")
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["EXISTING"] as? String, "1")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:18317")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "k")
    }

    func testAnthropicBaseKeepsRootWithoutVersion() {
        XCTAssertEqual(AgentAdapters.anthropicBase("http://127.0.0.1:18317/v1"), "http://127.0.0.1:18317")
        XCTAssertEqual(AgentAdapters.anthropicBase("http://host:1/v1/"), "http://host:1")
        XCTAssertEqual(AgentAdapters.anthropicBase("http://host:1/api"), "http://host:1/api")
    }

    func testEnvUpsertReplacesInPlaceAndKeepsComments() {
        let input = """
        # comment
        OPENAI_BASE_URL="http://old"
        OTHER=1
        """
        let output = AgentAdapters.upsertEnvValue(in: input, key: "OPENAI_BASE_URL", value: "http://new")
        XCTAssertTrue(output.contains("# comment"))
        XCTAssertTrue(output.contains("OPENAI_BASE_URL=\"http://new\""))
        XCTAssertTrue(output.contains("OTHER=1"))
        XCTAssertEqual(output.components(separatedBy: "OPENAI_BASE_URL=").count - 1, 1)
    }

    func testOpenCodeJSONAddsProviderBlock() throws {
        let output = try adapterText("opencode", current: "{\n  \"theme\": \"dark\"\n}\n", model: "gpt-5")
        let data = try XCTUnwrap(output.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "dark")
        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        let melon = try XCTUnwrap(providers["melon"] as? [String: Any])
        XCTAssertEqual(melon["npm"] as? String, "@ai-sdk/openai-compatible")
        let options = try XCTUnwrap(melon["options"] as? [String: Any])
        XCTAssertEqual(options["baseURL"] as? String, "http://127.0.0.1:18317/v1")
        XCTAssertNotNil(melon["models"] as? [String: Any])
    }

    func testInvalidJSONIsRefused() {
        XCTAssertThrowsError(try adapterText("opencode", current: "{not json", model: "m"))
    }

    func testCodexRouteGetsModelAndProvider() throws {
        let output = try adapterText("codex", current: "model = \"old\"\n", model: "gpt-5")
        XCTAssertTrue(output.contains("model_provider = \"melon_local_access\""))
        XCTAssertTrue(output.contains("model = \"gpt-5\""))
        XCTAssertTrue(output.contains("[model_providers.melon_local_access]"))
        XCTAssertTrue(output.contains("experimental_bearer_token = \"k\""))
    }

    func testEmptyModelIsRefusedForModelAwareAgents() {
        XCTAssertThrowsError(try adapterText("codex", model: "  "))
    }

    func testNestedJSONPathCreatesObjects() {
        var root: [String: Any] = ["keep": true]
        AgentStore.setJSONPath(root: &root, path: "env.OPENAI_BASE_URL", value: "http://x")
        XCTAssertEqual(root["keep"] as? Bool, true)
        let env = root["env"] as? [String: Any]
        XCTAssertEqual(env?["OPENAI_BASE_URL"] as? String, "http://x")
    }

    func testCustomAgentValidation() {
        let agent = CustomAgent(
            title: "",
            configPath: "relative/path.json",
            format: .json,
            baseURLKey: "",
            apiKeyKey: ""
        )
        XCTAssertNotNil(AgentStore.validate(custom: agent, existing: []))
        var fixed = agent
        fixed.title = "Mine"
        fixed.configPath = "~/.mine/config.json"
        fixed.baseURLKey = "baseURL"
        fixed.apiKeyKey = "apiKey"
        XCTAssertNil(AgentStore.validate(custom: fixed, existing: []))
        XCTAssertNotNil(AgentStore.validate(custom: fixed, existing: [fixed]))
    }

    // MARK: - Agent adapters

    private var context: AgentApplyContext {
        AgentApplyContext(
            baseURL: "http://127.0.0.1:8787/v1",
            apiKey: "sk-test",
            model: "test-model",
            effort: "high"
        )
    }

    private func object(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCatalogHasTheFourMissingAgents() {
        XCTAssertNotNil(AgentCatalog.agent(id: "antigravity"))
        XCTAssertNotNil(AgentCatalog.agent(id: "cursor-cli"))
        XCTAssertNotNil(AgentCatalog.agent(id: "vscode"))
        XCTAssertNotNil(AgentCatalog.agent(id: "dsh"))
        XCTAssertEqual(AgentCatalog.agent(id: "vscode")?.configPaths.count, 2)
        XCTAssertEqual(AgentCatalog.agent(id: "opencode")?.configPaths.first, "~/.config/opencode/opencode.jsonc")
        XCTAssertEqual(AgentCatalog.agent(id: "dsh")?.effortOptions, ["off", "low", "high", "max"])
        XCTAssertEqual(AgentCatalog.agent(id: "claude")?.effortOptions.contains("xhigh"), true)
        XCTAssertEqual(AgentCatalog.agent(id: "codex")?.fields, [AgentDefinition.Field.model, .effort])
    }

    func testJSONCAcceptsCommentsAndTrailingCommas() throws {
        let text = """
        {
          // a comment
          "theme": "dark", /* another */
          "list": [1, 2,],
        }
        """
        let root = try AgentAdapters.parseJSONC(text, path: "test.jsonc") as? [String: Any]
        XCTAssertEqual(root?["theme"] as? String, "dark")
        XCTAssertEqual((root?["list"] as? [Any])?.count, 2)
    }

    func testOpenCodeWritesProviderAndKeepsOtherKeys() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "opencode"))
        let url = URL(fileURLWithPath: "/tmp/melon-opencode.jsonc")
        let edits = try AgentAdapters.edits(
            definition: definition,
            urls: [url],
            files: [url.path: "{\n  // keep me\n  \"theme\": \"dark\"\n}\n"],
            context: context
        )
        XCTAssertEqual(edits.count, 1)
        let root = try object(edits[0].text)
        XCTAssertEqual(root["theme"] as? String, "dark")
        XCTAssertEqual(root["model"] as? String, "melon/test-model")
        let provider = root["provider"] as? [String: Any]
        XCTAssertNotNil(provider?["melon"])
    }

    func testClaudeWritesModelAndEffort() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "claude"))
        let url = URL(fileURLWithPath: "/tmp/melon-claude-settings.json")
        let edits = try AgentAdapters.edits(
            definition: definition,
            urls: [url],
            files: [:],
            context: context
        )
        let root = try object(edits[0].text)
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "test-model")
        XCTAssertEqual(env["CLAUDE_CODE_EFFORT_LEVEL"] as? String, "high")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:8787")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-test")
    }

    func testCodexWritesEffort() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "codex"))
        let url = URL(fileURLWithPath: "/tmp/melon-codex-config.toml")
        let edits = try AgentAdapters.edits(
            definition: definition,
            urls: [url],
            files: [url.path: "model = \"old\"\n"],
            context: context
        )
        XCTAssertTrue(edits[0].text.contains("model_reasoning_effort = \"high\""))
        XCTAssertTrue(edits[0].text.contains("model = \"test-model\""))
    }

    func testVSCodeKeepsOtherGroupsAndPointsDefaultModel() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "vscode"))
        let settings = URL(fileURLWithPath: "/tmp/melon-vscode-settings.json")
        let models = URL(fileURLWithPath: "/tmp/melon-vscode-models.json")
        let edits = try AgentAdapters.edits(
            definition: definition,
            urls: [settings, models],
            files: [models.path: "[{\"name\": \"Other\", \"vendor\": \"x\"}]"],
            context: context
        )
        XCTAssertEqual(edits.count, 2)
        let settingsRoot = try object(edits[0].text)
        XCTAssertEqual(settingsRoot["chat.defaultModel"] as? String, "test-model")
        let list = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(edits[1].text.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first?["name"] as? String, "Other")
        XCTAssertEqual(list.last?["name"] as? String, "Melon Tools")
    }

    func testDSHPatchIsIdempotent() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "dsh"))
        let url = URL(fileURLWithPath: "/tmp/melon-dsh.yml")
        let first = try AgentAdapters.edits(
            definition: definition, urls: [url], files: [:], context: context
        )[0]
        let second = try AgentAdapters.edits(
            definition: definition, urls: [url], files: [url.path: first.text], context: context
        )[0]
        XCTAssertEqual(first.text, second.text)
        XCTAssertEqual(first.text.components(separatedBy: "- id: llm-deepseek").count, 2)
        XCTAssertTrue(first.text.contains("reasoningEffort: \"high\""))
        XCTAssertTrue(first.text.contains("baseURL: \"http://127.0.0.1:8787/v1\""))
        XCTAssertFalse(first.text.contains("/v1/v1"))
        XCTAssertTrue(first.text.contains("provider: deepseek-official"))
    }

    func testDSHPatchKeepsForeignCommentsAndKeys() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "dsh"))
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent("melon-dsh-foreign-\(UUID().uuidString).yml")
        let foreign = """
        # my own header
        provider: my-provider # keep me

        - id: llm-deepseek # melon-tools
          baseURL: "http://old:1/v1"

        # a note between managed blocks
        other-key: keep-me-too

        - id: agent-default-model # melon-tools
          provider: old

        # trailing user note
        custom:
          key: value
        """
        let edits = try AgentAdapters.edits(
            definition: definition, urls: [url], files: [url.path: foreign], context: context
        )
        let text = try XCTUnwrap(edits.first?.text)
        XCTAssertTrue(text.contains("# my own header"))
        XCTAssertTrue(text.contains("# a note between managed blocks"))
        XCTAssertTrue(text.contains("other-key: keep-me-too"))
        XCTAssertTrue(text.contains("# trailing user note"))
        XCTAssertTrue(text.contains("custom:"))
        XCTAssertTrue(text.contains("key: value"))
        XCTAssertEqual(text.components(separatedBy: "- id: llm-deepseek").count, 2)
        XCTAssertEqual(text.components(separatedBy: "- id: agent-default-model").count, 2)
    }

    func testAntigravityWritesGatewayBlock() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "antigravity"))
        let url = URL(fileURLWithPath: "/tmp/melon-antigravity-config.json")
        let edits = try AgentAdapters.edits(
            definition: definition,
            urls: [url],
            files: [:],
            context: context
        )
        let root = try object(edits[0].text)
        let gateway = try XCTUnwrap(root["gateway"] as? [String: Any])
        XCTAssertEqual(gateway["enabled"] as? Bool, true)
        XCTAssertEqual(gateway["wireProtocol"] as? String, "openai")
        let models = try XCTUnwrap(root["models"] as? [String: Any])
        XCTAssertEqual(models["defaultModelId"] as? String, "test-model")
    }

    func testCursorCLIWritesModelBlock() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "cursor-cli"))
        let url = URL(fileURLWithPath: "/tmp/melon-cursor-cli.json")
        let edits = try AgentAdapters.edits(
            definition: definition,
            urls: [url],
            files: [:],
            context: context
        )
        let root = try object(edits[0].text)
        let model = try XCTUnwrap(root["model"] as? [String: Any])
        XCTAssertEqual(model["modelId"] as? String, "test-model")
        XCTAssertEqual(root["hasChangedDefaultModel"] as? Bool, true)
    }

    func testContentHashIgnoresEditOrder() {
        let a = AgentFileEdit(path: "/a", text: "1")
        let b = AgentFileEdit(path: "/b", text: "2")
        XCTAssertEqual(AgentStore.contentHash([a, b]), AgentStore.contentHash([b, a]))
        XCTAssertNotEqual(AgentStore.contentHash([a, b]), AgentStore.contentHash([a]))
    }

    func testManualAgentRefusesToWrite() throws {
        let definition = try XCTUnwrap(AgentCatalog.agent(id: "zed"))
        let url = URL(fileURLWithPath: "/tmp/melon-zed.json")
        XCTAssertThrowsError(
            try AgentAdapters.edits(definition: definition, urls: [url], files: [:], context: context)
        )
    }
}
