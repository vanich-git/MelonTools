import XCTest
@testable import MelonTools

final class LoopbackServerTests: XCTestCase {
    func testLoopbackHostAcceptsLoopbackNames() {
        XCTAssertTrue(LoopbackServer.loopbackHost("GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n\r\n"))
        XCTAssertTrue(LoopbackServer.loopbackHost("GET /auth/callback HTTP/1.1\r\nHost: 127.0.0.1:1455\r\n\r\n"))
        XCTAssertTrue(LoopbackServer.loopbackHost("GET /auth/callback HTTP/1.1\r\nHost: [::1]:1455\r\n\r\n"))
        XCTAssertTrue(LoopbackServer.loopbackHost("GET /auth/callback HTTP/1.1\r\nHost: LOCALHOST\r\n\r\n"))
    }

    func testLoopbackHostRejectsForeignOrMissingHost() {
        XCTAssertFalse(LoopbackServer.loopbackHost("GET /auth/callback HTTP/1.1\r\nHost: evil.example\r\n\r\n"))
        XCTAssertFalse(LoopbackServer.loopbackHost("GET /auth/callback HTTP/1.1\r\nHost: 127.0.0.1.evil.example\r\n\r\n"))
        XCTAssertFalse(LoopbackServer.loopbackHost("GET /auth/callback HTTP/1.1\r\n\r\n"))
    }
}
