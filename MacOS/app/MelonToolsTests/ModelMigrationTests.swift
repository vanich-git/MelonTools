import XCTest
@testable import MelonTools

final class ModelMigrationTests: XCTestCase {
    
    func testMigrationPersistedNewPreservesKey() throws {
        let json = """
        {
            "openRouterConfig": {
                "key": "sk-12345",
                "enabled": true,
                "providerSettings": {},
                "defaultStrategy": "price"
            },
            "openCodeKey": "oc-67890"
        }
        """.data(using: .utf8)!
        
        // This is a simplified simulation of what ModelSourcesStore.load() does
        struct PersistedNew: Codable {
            var openRouterConfig: OpenRouterConfig?
            var openRouterKey: String?
            var openCodeKey: String?
        }
        
        let persisted = try JSONDecoder().decode(PersistedNew.self, from: json)
        let key = persisted.openRouterConfig?.key ?? persisted.openRouterKey ?? ""
        XCTAssertEqual(key, "sk-12345")
        XCTAssertEqual(persisted.openCodeKey, "oc-67890")
    }
}
