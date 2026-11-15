import XCTest
@testable import MelonTools

@MainActor
final class OpenRouterRoutingTests: XCTestCase {
    
    func testOpenRouterKeyRoundTripUsesEditableKey() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("model-sources.json")
        let store = ModelSourcesStore(storeURL: storeURL)
        store.openRouterConfig.key = "stale-key"
        store.openRouterKey = "current-key"
        store.save()
        let reloaded = ModelSourcesStore(storeURL: storeURL)
        XCTAssertEqual(reloaded.openRouterKey, "current-key")
        XCTAssertEqual(reloaded.openRouterConfig.key, "current-key")
    }

    func testOpenRouterMergePreservesSettings() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("model-sources.json")
        let store = ModelSourcesStore(storeURL: storeURL)
        
        // 1. Создаем модель с настройками
        let existingModel = SourceModel(
            id: "test-model",
            display: "Test Model",
            contextLength: 4096,
            enabled: true,
            alias: "openrouter/test-model",
            provider: "test-provider",
            sortOrder: "price",
            fallback: true,
            isFloorModel: true,
            isNitroModel: false
        )
        store.mergeOpenRouter(entries: [ModelSourcesStore.ModelList.Entry(
            id: existingModel.id, name: existingModel.display, type: nil,
            context_length: existingModel.contextLength, context_window: nil,
            owned_by: nil, pricing: nil, architecture: nil, metadata: nil,
            modalities: nil, supported_endpoints: nil
        )], key: "test-key")
        store.setModel("openrouter", modelId: existingModel.id, enabled: true)
        store.setModelProvider("openrouter", modelId: existingModel.id, provider: existingModel.provider)
        store.setModelSortOrder("openrouter", modelId: existingModel.id, sortOrder: existingModel.sortOrder)
        store.setModelFallback("openrouter", modelId: existingModel.id, fallback: existingModel.fallback)
        store.setModelIsFloorModel("openrouter", modelId: existingModel.id, isFloorModel: existingModel.isFloorModel)
        store.setModelIsNitroModel("openrouter", modelId: existingModel.id, isNitroModel: existingModel.isNitroModel)
        
        // 2. Мержим (симулируем обновление)
        let entry = ModelSourcesStore.ModelList.Entry(
            id: "test-model",
            name: "Test Model",
            type: nil,
            context_length: 4096,
            context_window: nil,
            owned_by: nil,
            pricing: nil,
            architecture: nil,
            metadata: nil,
            modalities: nil,
            supported_endpoints: nil
        )
        store.mergeOpenRouter(entries: [entry], key: "test-key")
        
        // 3. Проверяем
        let mergedModel = store.openRouterSource?.models.first { $0.id == "test-model" }
        XCTAssertNotNil(mergedModel, "Модель должна сохраниться")
        XCTAssertEqual(mergedModel?.provider, "test-provider")
        XCTAssertEqual(mergedModel?.sortOrder, "price")
        XCTAssertEqual(mergedModel?.fallback, true)
        XCTAssertEqual(mergedModel?.isFloorModel, true)
        XCTAssertEqual(mergedModel?.isNitroModel, false)
    }

    func testOpenRouterFreeTierRequiresExplicitZeroPrices() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = ModelSourcesStore(storeURL: tempDir.appendingPathComponent("model-sources.json"))
        let entries = [
            ModelSourcesStore.ModelList.Entry(id: "provider/model:free", name: nil, type: nil, context_length: nil, context_window: nil, owned_by: nil, pricing: nil, architecture: nil, metadata: nil, modalities: nil, supported_endpoints: nil),
            try JSONDecoder().decode(ModelSourcesStore.ModelList.Entry.self, from: Data(#"{"id":"provider/zero","pricing":{"prompt":"0","completion":"0"}}"#.utf8)),
            try JSONDecoder().decode(ModelSourcesStore.ModelList.Entry.self, from: Data(#"{"id":"provider/partial","pricing":{"prompt":"0"}}"#.utf8)),
            ModelSourcesStore.ModelList.Entry(id: "provider/unknown-price", name: nil, type: nil, context_length: nil, context_window: nil, owned_by: nil, pricing: nil, architecture: nil, metadata: nil, modalities: nil, supported_endpoints: nil)
        ]

        store.mergeOpenRouter(entries: entries, key: "test-key")

        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "provider/model:free" }?.freeTier, true)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "provider/zero" }?.freeTier, true)
        XCTAssertNil(store.openRouterSource?.models.first { $0.id == "provider/unknown-price" }?.freeTier)

        store.setAllModels("openrouter", enabled: true, matching: "  PROVIDER  ", freeOnly: true)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "provider/model:free" }?.enabled, true)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "provider/zero" }?.enabled, true)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "provider/partial" }?.enabled, false)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "provider/unknown-price" }?.enabled, false)
        store.setAllModels("openrouter", enabled: false, matching: "zero", freeOnly: true)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "provider/model:free" }?.enabled, true)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "provider/zero" }?.enabled, false)
    }

    func testHydrationMarksLegacyFreeModels() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = ModelSourcesStore(storeURL: tempDir.appendingPathComponent("model-sources.json"))
        let legacy = try ["vendor/free:free", "vendor/zero", "vendor/unknown"].map { id in
            try JSONDecoder().decode(ModelSourcesStore.ModelList.Entry.self, from: Data("{\"id\":\"\(id)\"}".utf8))
        }
        store.mergeOpenRouter(entries: legacy, key: "key")
        let zero = try JSONDecoder().decode(ModelSourcesStore.ModelList.Entry.self,
                                            from: Data(#"{"id":"vendor/zero","pricing":{"prompt":"0","completion":"0"}}"#.utf8))
        store.mergeOpenRouterPricing(entries: [zero])
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "vendor/zero" }?.freeTier, true)
        XCTAssertNil(store.openRouterSource?.models.first { $0.id == "vendor/unknown" }?.freeTier)
        let reloaded = ModelSourcesStore(storeURL: tempDir.appendingPathComponent("model-sources.json"))
        XCTAssertEqual(reloaded.openRouterSource?.models.first { $0.id == "vendor/zero" }?.freeTier, true)
    }

    func testHydrationRepairsKnownFreePricesWithoutNetwork() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("model-sources.json")
        let json = #"{"openRouterKey":"key","sources":[{"id":"openrouter","kind":"openRouter","title":"OpenRouter","baseURL":"https://openrouter.ai/api/v1","apiKey":"key","enabled":true,"models":[{"id":"vendor/zero","display":"Zero","enabled":true,"alias":"openrouter/vendor/zero","promptPerToken":0,"completionPerToken":0},{"id":"vendor/paid","display":"Paid","enabled":true,"alias":"openrouter/vendor/paid","promptPerToken":1,"completionPerToken":1}]}]}"#
        try Data(json.utf8).write(to: storeURL)
        let store = ModelSourcesStore(storeURL: storeURL)
        XCTAssertTrue(try XCTUnwrap(store.openRouterSource?.models.first { $0.id == "vendor/zero" }).isOpenRouterFree)
        store.setAllModels("openrouter", enabled: false, freeOnly: true)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "vendor/zero" }?.enabled, false)
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "vendor/paid" }?.enabled, true)
        await store.hydrateOpenRouterPrices()
        XCTAssertEqual(store.openRouterSource?.models.first { $0.id == "vendor/zero" }?.freeTier, true)
        XCTAssertNil(store.openRouterSource?.models.first { $0.id == "vendor/paid" }?.freeTier)
        XCTAssertEqual(ModelSourcesStore(storeURL: storeURL).openRouterSource?.models.first { $0.id == "vendor/zero" }?.freeTier, true)
    }

    func testVariantsAppearInGeneratedCatalogAndPicker() throws {
        let model = SourceModel(id: "provider/model", display: "Example", contextLength: 4096,
                                enabled: true, alias: "openrouter/provider/model",
                                isFloorModel: true, isNitroModel: true)
        let source = ModelSource(id: "openrouter", kind: .openRouter, title: "OpenRouter",
                                 baseURL: "https://openrouter.ai/api/v1", apiKey: "test-key",
                                 enabled: true, models: [model])
        let base: [[String: Any]] = [["slug": "base", "display_name": "Base", "context_window": 4096, "priority": 0]]
        let catalog = CodexModelCatalog.generatedEntries(base: base, sources: [source], defaults: nil)
        let slugs = Set(catalog.entries.compactMap { $0["slug"] as? String })
        XCTAssertTrue(slugs.contains("openrouter/provider/model:floor"))
        XCTAssertTrue(slugs.contains("openrouter/provider/model:nitro"))
        let picker = CodexModelCatalog.pickerIndex(sources: [source])
        XCTAssertTrue(picker.contains { $0.slug == "openrouter/provider/model:floor" })
        XCTAssertTrue(picker.contains { $0.slug == "openrouter/provider/model:nitro" })
    }

    func testPriceRoutingYAMLGeneration() throws {
        let model = SourceModel(
            id: "test-model",
            display: "Test Model",
            contextLength: 4096,
            enabled: true,
            alias: "openrouter/test-model",
            provider: "openai",
            sortOrder: "throughput",
            fallback: true,
            isFloorModel: true,
            isNitroModel: true
        )
        let source = ModelSource(
            id: "openrouter",
            kind: .openRouter,
            title: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "test-key",
            enabled: true,
            models: [model]
        )
        
        let yaml = ModelSourcesStore.gatewayYAML(sources: [source])
        let configLines = yaml.components(separatedBy: "\n")
        XCTAssertTrue(yaml.contains("payload:\n  default-raw:\n    - models:\n        - name:"))
        XCTAssertTrue(configLines.contains("        - name: \"test-model\""))
        XCTAssertTrue(configLines.contains("          alias: \"openrouter/test-model\""))
        XCTAssertTrue(configLines.contains("        - name: \"test-model:floor\""))
        XCTAssertTrue(configLines.contains("          alias: \"openrouter/test-model:floor\""))
        XCTAssertTrue(configLines.contains("        - name: \"test-model:nitro\""))
        XCTAssertTrue(configLines.contains("          alias: \"openrouter/test-model:nitro\""))
        XCTAssertTrue(yaml.contains("\"openrouter/test-model:floor\""))
        XCTAssertTrue(yaml.contains("\"openrouter/test-model:nitro\""))

        let alreadyVariant = SourceModel(
            id: "test-model:floor",
            display: "Test Model Floor",
            contextLength: 4096,
            enabled: true,
            alias: "openrouter/test-model:floor",
            isFloorModel: true,
            isNitroModel: false
        )
        var sourceWithVariant = source
        sourceWithVariant.models = [alreadyVariant]
        let variantYAML = ModelSourcesStore.gatewayYAML(sources: [sourceWithVariant])
        XCTAssertTrue(variantYAML.contains("        - name: \"test-model:floor\""))
        XCTAssertTrue(variantYAML.contains("          alias: \"openrouter/test-model:floor\""))
        XCTAssertFalse(variantYAML.contains("test-model:floor:floor"))
        XCTAssertFalse(variantYAML.contains("openrouter/test-model:floor:floor"))
        
        // Проверяем JSON параметров
        XCTAssertTrue(yaml.contains("\\\"allow_fallbacks\\\":true"))
        XCTAssertTrue(yaml.contains("\\\"order\\\":[\\\"openai\\\"]"))
        XCTAssertTrue(yaml.contains("\\\"sort\\\":\\\"throughput\\\""))

        var defaultSort = model
        defaultSort.sortOrder = nil
        sourceWithVariant.models = [defaultSort]
        let defaultYAML = ModelSourcesStore.gatewayYAML(sources: [sourceWithVariant])
        XCTAssertTrue(defaultYAML.contains("\\\"sort\\\":\\\"price\\\""))
        XCTAssertTrue(defaultYAML.contains("\\\"order\\\":[\\\"openai\\\"]"))
        XCTAssertTrue(defaultYAML.contains("\\\"allow_fallbacks\\\":true"))
        let rules = defaultYAML.components(separatedBy: "    - models:\n").dropFirst()
        let floor = try XCTUnwrap(rules.first { $0.contains("name: \"openrouter/test-model:floor\"") })
        let nitro = try XCTUnwrap(rules.first { $0.contains("name: \"openrouter/test-model:nitro\"") })
        XCTAssertTrue(floor.contains("\\\"sort\\\":\\\"price\\\""))
        XCTAssertTrue(nitro.contains("\\\"sort\\\":\\\"throughput\\\""))
        XCTAssertTrue(nitro.contains("\\\"order\\\":[\\\"openai\\\"]"))
    }
}
