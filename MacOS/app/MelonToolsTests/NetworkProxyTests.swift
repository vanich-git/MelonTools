import CFNetwork
import XCTest
@testable import MelonTools

final class NetworkProxyTests: XCTestCase {
    func testSOCKSProxyDictionaryIncludesBypass() throws {
        let dictionary = try XCTUnwrap(NetworkProxy.proxyDictionary(
            for: "socks5h://127.0.0.1:1080",
            bypass: "127.0.0.1, localhost"
        ))
        XCTAssertEqual(dictionary["SOCKSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary["SOCKSPort"] as? Int, 1080)
        XCTAssertEqual(dictionary["ExceptionsList"] as? [String], ["127.0.0.1", "localhost"])
    }

    func testSOCKSProxyDictionaryCarriesCredentials() throws {
        let dictionary = try XCTUnwrap(NetworkProxy.proxyDictionary(
            for: "socks5://user:p%40ss@proxy.example:1080",
            bypass: "127.0.0.1,localhost"
        ))
        XCTAssertEqual(dictionary["SOCKSUser"] as? String, "user")
        XCTAssertEqual(dictionary["SOCKSPassword"] as? String, "p@ss")
    }

    func testHTTPProxyDictionaryCarriesCredentials() throws {
        let dictionary = try XCTUnwrap(NetworkProxy.proxyDictionary(
            for: "http://user:secret@proxy.example:8080",
            bypass: "127.0.0.1,localhost"
        ))
        XCTAssertEqual(dictionary["HTTPUser"] as? String, "user")
        XCTAssertEqual(dictionary["HTTPPassword"] as? String, "secret")
        XCTAssertEqual(dictionary["HTTPSUser"] as? String, "user")
        XCTAssertEqual(dictionary["HTTPSPassword"] as? String, "secret")
    }

    func testHTTPProxyDictionaryCoversHTTPAndHTTPS() throws {
        let dictionary = try XCTUnwrap(NetworkProxy.proxyDictionary(
            for: "http://proxy.example:8080",
            bypass: "127.0.0.1,localhost"
        ))
        XCTAssertEqual(dictionary["HTTPProxy"] as? String, "proxy.example")
        XCTAssertEqual(dictionary["HTTPSProxy"] as? String, "proxy.example")
        XCTAssertEqual(dictionary["HTTPPort"] as? Int, 8080)
        XCTAssertEqual(dictionary["HTTPSPort"] as? Int, 8080)
    }

    func testInvalidProxyURLIsRejected() {
        XCTAssertNil(NetworkProxy.proxyDictionary(for: "not a url", bypass: "localhost"))
    }

    func testSystemProxyResolutionMapsHTTPAndSOCKS() {
        let http: [[String: Any]] = [
            [
                kCFProxyTypeKey as String: kCFProxyTypeHTTP as String,
                kCFProxyHostNameKey as String: "proxy.example",
                kCFProxyPortNumberKey as String: NSNumber(value: 8080),
            ],
        ]
        XCTAssertEqual(NetworkProxy.proxyURL(from: http), "http://proxy.example:8080")

        let socks: [[String: Any]] = [
            [
                kCFProxyTypeKey as String: kCFProxyTypeSOCKS as String,
                kCFProxyHostNameKey as String: "127.0.0.1",
                kCFProxyPortNumberKey as String: NSNumber(value: 1080),
            ],
        ]
        XCTAssertEqual(NetworkProxy.proxyURL(from: socks), "socks5://127.0.0.1:1080")
    }

    func testSystemProxyResolutionHonoursDirectResult() {
        let direct: [[String: Any]] = [
            [kCFProxyTypeKey as String: kCFProxyTypeNone as String],
        ]
        XCTAssertNil(NetworkProxy.proxyURL(from: direct))
        XCTAssertNil(NetworkProxy.proxyURL(from: []))
    }
}
