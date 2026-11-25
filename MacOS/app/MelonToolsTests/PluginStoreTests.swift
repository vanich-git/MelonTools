import XCTest
@testable import MelonTools

final class PluginStoreTests: XCTestCase {
    /// The on-disk cache is written by `JSONEncoder` and read by the engine's
    /// snake_case decoder. Encoding therefore has to use the same coding keys
    /// as decoding, or the next offline launch silently loses the catalog.
    func testStoreCacheRoundTripsEngineKeys() throws {
        let raw = """
        {
          "plugins_enabled": true,
          "plugins_dir": "/tmp/melon-plugins",
          "sources": [
            {"id": "official", "name": "Official", "url": "https://example.com/registry.json"}
          ],
          "source_errors": [
            {"source_id": "melon", "source_name": "Melon Registry", "source_url": "https://example.com/melon.json", "message": "offline"}
          ],
          "plugins": [
            {
              "id": "sample-plugin",
              "store_id": "official/sample-plugin",
              "source_id": "official",
              "source_name": "Official",
              "source_url": "https://example.com/registry.json",
              "name": "Sample Plugin",
              "description": "A fixture entry.",
              "author": "Melon",
              "version": "1.2.3",
              "install_type": "github-release",
              "platforms": [{"goos": "darwin", "goarch": "arm64"}],
              "tags": ["Usage"],
              "installed": true,
              "installed_version": "1.2.2",
              "enabled": true,
              "effective_enabled": true,
              "update_available": true
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(PluginStoreResponse.self, from: Data(raw.utf8))
        let encoded = try JSONEncoder().encode(decoded)
        let returned = try JSONDecoder().decode(PluginStoreResponse.self, from: encoded)

        XCTAssertTrue(returned.pluginsEnabled)
        XCTAssertEqual(returned.pluginsDir, "/tmp/melon-plugins")
        XCTAssertEqual(returned.sources.first?.sourceID, "official")
        XCTAssertEqual(returned.sourceErrors.first?.sourceName, "Melon Registry")
        let entry = try XCTUnwrap(returned.plugins.first)
        XCTAssertEqual(entry.pluginID, "sample-plugin")
        XCTAssertEqual(entry.storeID, "official/sample-plugin")
        XCTAssertEqual(entry.version, "1.2.3")
        XCTAssertEqual(entry.installedVersion, "1.2.2")
        XCTAssertEqual(entry.platforms.first?.label, "macOS Apple silicon")
        XCTAssertTrue(entry.updateAvailable)
        XCTAssertTrue(entry.effectiveEnabled)
    }

    func testJSONEditorAcceptsOnlyTheDeclaredContainerType() throws {
        let list = try PluginJSON.parseEditorText("[1, 2]", type: .array)
        XCTAssertEqual(list, .array([.int(1), .int(2)]))
        XCTAssertThrowsError(try PluginJSON.parseEditorText("{\"a\": 1}", type: .array))
        XCTAssertThrowsError(try PluginJSON.parseEditorText("not a number", type: .integer))
    }

    /// The engine parses the plugin block as YAML, so a quote or backslash in a
    /// path has to be escaped, and control scalars have to be dropped. The
    /// Windows `gateway::yaml_escape` produces the same output.
    func testYAMLScalarEscapesLikeTheWindowsWriter() {
        XCTAssertEqual(PluginSettings.yamlScalar("C:\\Melon\\plugins"), "C:\\\\Melon\\\\plugins")
        XCTAssertEqual(PluginSettings.yamlScalar("/tmp/a\"b"), "/tmp/a\\\"b")
        XCTAssertEqual(PluginSettings.yamlScalar("line\nbreak"), "linebreak")
        XCTAssertEqual(PluginSettings.yamlScalar("bell\u{07}del\u{7F}c1\u{85}"), "belldelc1")
        XCTAssertEqual(PluginSettings.yamlScalar("/plain/path"), "/plain/path")
    }
}
