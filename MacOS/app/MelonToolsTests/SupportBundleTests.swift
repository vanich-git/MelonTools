import XCTest
@testable import MelonTools

@MainActor
final class SupportBundleTests: XCTestCase {
    func testRedactsCommonSecretShapes() {
        let text = """
        Authorization: Bearer abc.def.ghi
        api_key: sk-or-v1-1234567890
        management-secret: melon-secret-value
        password = hunter2
        """
        let redacted = SupportBundleService.redact(text)
        XCTAssertFalse(redacted.contains("abc.def.ghi"))
        XCTAssertFalse(redacted.contains("sk-or-v1-1234567890"))
        XCTAssertFalse(redacted.contains("melon-secret-value"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("[redacted]"))
    }
}
