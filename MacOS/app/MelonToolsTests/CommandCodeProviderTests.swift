import XCTest
@testable import MelonTools

@MainActor
final class CommandCodeProviderTests: XCTestCase {
    private func model(_ id: String, anthropicOnly: Bool) -> SourceModel {
        SourceModel(
            id: id,
            display: id,
            contextLength: 1_000_000,
            enabled: true,
            alias: ModelSourcesStore.commandCodeAlias(id),
            anthropicOnly: anthropicOnly
        )
    }

    func testAliasIsNamespacedAndIdempotent() {
        XCTAssertEqual(
            ModelSourcesStore.commandCodeAlias("gpt-6-astra"),
            "commandcode/gpt-6-astra"
        )
        XCTAssertEqual(
            ModelSourcesStore.commandCodeAlias("commandcode/gpt-6-astra"),
            "commandcode/gpt-6-astra"
        )
    }

    /// CommandCode splits one catalogue over two upstream shapes: `/messages`-only
    /// models cannot ride `openai-compatibility`, so they go into `api-keys.claude`
    /// while keeping the same `commandcode/` alias prefix.
    func testGatewayYAMLSplitsModelsBySupportedEndpoint() {
        let source = ModelSource(
            id: "commandcode",
            kind: .commandCode,
            title: "CommandCode",
            baseURL: ModelSourcesStore.commandCodeBaseURL,
            apiKey: "cmd-key",
            enabled: true,
            models: [
                model("claude-sonnet-5-5", anthropicOnly: true),
                model("gpt-6-astra", anthropicOnly: false),
            ]
        )

        let yaml = ModelSourcesStore.gatewayYAML(sources: [source])

        guard let claudeStart = yaml.range(of: "  claude:\n") else {
            return XCTFail("no claude block in:\n\(yaml)")
        }
        let openAIPart = String(yaml[..<claudeStart.lowerBound])
        let claudePart = String(yaml[claudeStart.lowerBound...])

        XCTAssertEqual(yaml.components(separatedBy: "api-keys:").count - 1, 1)
        XCTAssertTrue(openAIPart.contains("  openai-compatibility:\n"))
        XCTAssertTrue(openAIPart.contains("    - name: \"commandcode\"\n"))
        XCTAssertTrue(
            openAIPart.contains(
                "      base-url: \"https://api.commandcode.ai/provider/v1\"\n"
            )
        )
        XCTAssertTrue(openAIPart.contains("        - api-key: \"cmd-key\"\n"))
        XCTAssertTrue(
            openAIPart.contains(
                "        - name: \"gpt-6-astra\"\n          alias: \"commandcode/gpt-6-astra\"\n"
            )
        )
        XCTAssertFalse(openAIPart.contains("claude-sonnet-5-5"))

        XCTAssertTrue(claudePart.contains("    - name: \"commandcode-anthropic\"\n"))
        XCTAssertTrue(
            claudePart.contains(
                "        - name: \"claude-sonnet-5-5\"\n          alias: \"commandcode/claude-sonnet-5-5\"\n"
            )
        )
        XCTAssertFalse(claudePart.contains("gpt-6-astra"))
    }

    /// Only `/messages` alone marks an Anthropic-only model; an absent list or
    /// one that also lists `/chat/completions` stays OpenAI-compatible.
    func testSupportedEndpointsDecideTheAnthropicRoute() throws {
        let json = Data(#"""
        {
          "object": "list",
          "data": [
            { "id": "claude-sonnet-5-5", "supported_endpoints": ["/messages"] },
            { "id": "gpt-6-astra", "supported_endpoints": ["/chat/completions", "/responses"] },
            { "id": "gpt-6.1-sol", "supported_endpoints": ["/chat/completions"] },
            { "id": "no-endpoints" }
          ]
        }
        """#.utf8)

        let entries = try JSONDecoder().decode(ModelSourcesStore.ModelList.self, from: json).data
        let anthropicOnly = entries.filter(ModelSourcesStore.commandCodeIsAnthropicOnly).map(\.id)

        XCTAssertEqual(anthropicOnly, ["claude-sonnet-5-5"])
    }
}
