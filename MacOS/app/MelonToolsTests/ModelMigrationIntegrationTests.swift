import XCTest
@testable import MelonTools

@MainActor
final class ModelMigrationIntegrationTests: XCTestCase {
    
    func testPersistenceRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let storeURL = tempDir.appendingPathComponent("model-sources.json")
        
        // 1. Save data using real ModelSourcesStore
        let store = ModelSourcesStore(storeURL: storeURL)
        store.openRouterConfig = OpenRouterConfig(key: "test-key", enabled: true, providerSettings: [:], defaultStrategy: "price")
        // save() rebuilds the persisted config from the editable field, so the
        // round trip only proves anything when both hold the same key.
        store.openRouterKey = "test-key"
        store.save()
        
        // 2. Load data using a new instance
        let reloadedStore = ModelSourcesStore(storeURL: storeURL)
        
        XCTAssertEqual(reloadedStore.openRouterConfig.key, "test-key")
        XCTAssertEqual(reloadedStore.openRouterKey, "test-key")
    }
}
