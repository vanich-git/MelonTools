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

    func testEmptyMemberListStaysEmpty() {
        XCTAssertTrue(RoutingGroupsStore.uniqueMembers([]).isEmpty)
    }
}
