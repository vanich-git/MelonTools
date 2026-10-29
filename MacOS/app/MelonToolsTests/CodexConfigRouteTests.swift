import XCTest
@testable import MelonTools

/// The route editor must never discard provider tables created by other tools
/// or by the user. Old chats also persist the provider id in their rollout
/// data, so the legacy `codex_local_access` alias has to stay resolvable.
final class CodexConfigRouteTests: XCTestCase {
    private let baseURL = "http://127.0.0.1:18317/v1"
    private let token = "test-gateway-key"

    func testUpsertPreservesThirdPartyProvidersAndAddsLegacyAlias() {
        let input = """
        model_provider = "openai"
        model_catalog_json = "old-catalog.json"

        [model_providers.cockpit]
        name = "Cockpit"
        base_url = "http://127.0.0.1:4000/v1"

        [model_providers.other]
        name = "Other"
        base_url = "http://127.0.0.1:4001/v1"
        """

        let output = CodexConfigRoute.upsertRoute(
            in: input, baseURL: baseURL, token: token
        )

        XCTAssertTrue(output.contains("model_provider = \"melon_local_access\""))
        XCTAssertTrue(output.contains("[model_providers.cockpit]"))
        XCTAssertTrue(output.contains("[model_providers.other]"))
        XCTAssertTrue(output.contains("[model_providers.melon_local_access]"))
        XCTAssertTrue(output.contains("[model_providers.codex_local_access]"))
        XCTAssertTrue(output.contains("base_url = \"\(baseURL)\""))
        XCTAssertTrue(output.contains("experimental_bearer_token = \"\(token)\""))

        let again = CodexConfigRoute.upsertRoute(
            in: output, baseURL: baseURL, token: token
        )
        XCTAssertEqual(again, output, "upsertRoute must be idempotent")
    }

    func testRemoveKeepsThirdPartyProvidersAndLegacyAlias() {
        let input = """
        model_provider = "openai"

        [model_providers.cockpit]
        name = "Cockpit"
        base_url = "http://127.0.0.1:4000/v1"
        """
        let applied = CodexConfigRoute.upsertRoute(
            in: input, baseURL: baseURL, token: token
        )
        let removed = CodexConfigRoute.removeRoute(in: applied)

        XCTAssertTrue(removed.contains("[model_providers.cockpit]"))
        XCTAssertFalse(removed.contains("[model_providers.melon_local_access]"))
        XCTAssertTrue(
            removed.contains("[model_providers.codex_local_access]"),
            "old chats must still find their provider alias"
        )
        XCTAssertFalse(removed.contains("model_provider = \"melon_local_access\""))
    }

    func testAliasIsRefreshedToTheCurrentGateway() {
        let applied = CodexConfigRoute.upsertRoute(
            in: "", baseURL: baseURL, token: token
        )
        let moved = CodexConfigRoute.upsertRoute(
            in: applied,
            baseURL: "http://127.0.0.1:19000/v1",
            token: "new-key"
        )
        XCTAssertTrue(moved.contains("http://127.0.0.1:19000/v1"))
        XCTAssertFalse(moved.contains(baseURL))
        XCTAssertEqual(
            moved.components(separatedBy: "[model_providers.codex_local_access]").count - 1,
            1
        )
    }
}
