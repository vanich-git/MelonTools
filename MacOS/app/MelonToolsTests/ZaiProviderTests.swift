import XCTest
@testable import MelonTools

@MainActor
final class ZaiProviderTests: XCTestCase {
    func testGatewayYAMLEmitsTheZaiCodingEndpointAndAlias() {
        let model = SourceModel(
            id: "glm-5.3",
            display: "GLM-5.3",
            contextLength: 1_000_000,
            enabled: true,
            alias: "zai/glm-5.3"
        )
        let source = ModelSource(
            id: "zai",
            kind: .zai,
            title: "Z.ai",
            baseURL: ModelSourcesStore.zaiBaseURL,
            apiKey: "id.secret",
            enabled: true,
            models: [model]
        )

        let yaml = ModelSourcesStore.gatewayYAML(sources: [source])

        XCTAssertTrue(yaml.contains("  openai-compatibility:\n"))
        XCTAssertTrue(yaml.contains("    - name: \"zai\"\n"))
        XCTAssertTrue(yaml.contains("      base-url: \"https://api.z.ai/api/coding/paas/v4\"\n"))
        XCTAssertTrue(yaml.contains("        - api-key: \"id.secret\"\n"))
        XCTAssertTrue(yaml.contains("        - name: \"glm-5.3\"\n          alias: \"zai/glm-5.3\"\n"))
    }

    func testAliasIsNamespacedAndIdempotent() {
        XCTAssertEqual(ModelSourcesStore.zaiAlias("glm-5.3"), "zai/glm-5.3")
        XCTAssertEqual(ModelSourcesStore.zaiAlias("zai/glm-5.3"), "zai/glm-5.3")
    }

    func testParsesOpenAICompatibleModelListAndImageCapability() throws {
        let data = Data(#"""
        {
          "data": [
            { "id": "glm-5.3", "name": "GLM-5.3", "context_length": 1000000 },
            {
              "id": "glm-5.3-flash",
              "name": "GLM-5.3 Flash",
              "context_window": 1000000,
              "architecture": { "input_modalities": ["text", "image"] }
            }
          ]
        }
        """#.utf8)

        let models = ModelSourcesStore.parseZaiModels(data)

        XCTAssertEqual(models.map(\.id), ["glm-5.3", "glm-5.3-flash"])
        XCTAssertEqual(models.first?.display, "GLM-5.3")
        XCTAssertEqual(models.first?.contextLength, 1_000_000)
        XCTAssertEqual(models.first?.supportsImages, false)
        XCTAssertEqual(models.last?.supportsImages, true)
    }

    func testFallbackCatalogMatchesTheCurrentCodingPlanModels() {
        XCTAssertEqual(
            ModelSourcesStore.zaiFallbackModels.map(\.id),
            ["glm-5.3", "glm-5.3-flash"]
        )
        XCTAssertEqual(ModelSourcesStore.zaiFallbackModels.first?.supportsImages, false)
        XCTAssertEqual(ModelSourcesStore.zaiFallbackModels.last?.supportsImages, true)
    }

    func testImageCapabilityDefaults() {
        XCTAssertEqual(ModelSourcesStore.zaiSupportsImages("glm-5.3"), false)
        XCTAssertEqual(ModelSourcesStore.zaiSupportsImages("glm-5.3-flash"), true)
        XCTAssertEqual(ModelSourcesStore.zaiSupportsImages("glm-5.3-flash-high"), true)
        XCTAssertEqual(ModelSourcesStore.zaiSupportsImages("glm-4.6v"), true)
        XCTAssertNil(ModelSourcesStore.zaiSupportsImages("some-other-model"))
    }
}
