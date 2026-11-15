import CFNetwork
import Network
import XCTest
@testable import MelonTools

final class NetworkProxyTests: XCTestCase {
    func testExternalRequestActuallyTraversesConfiguredHTTPProxy() async throws {
        let proxy = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "proxy listening")
        let requestSeen = expectation(description: "proxy received request")
        proxy.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        proxy.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                XCTAssertTrue(request.contains("example.invalid"))
                requestSeen.fulfill()
                XCTAssertTrue(request.hasPrefix("CONNECT "))
                // Reject the tunnel after proving routing. No external DNS or
                // test TLS certificate is needed, and ATS stays enforced.
                let response = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        proxy.start(queue: .global())
        defer { proxy.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(proxy.port).rawValue
        let defaults = UserDefaults.standard
        let keys = [NetworkProxy.enabledKey, NetworkProxy.urlKey, NetworkProxy.bypassKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: NetworkProxy.enabledKey)
        defaults.set("http://127.0.0.1:\(port)", forKey: NetworkProxy.urlKey)
        let config = NetworkProxy.externalConfiguration()
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: XCTUnwrap(URL(string: "https://example.invalid/audit")))
            XCTFail("The recording proxy intentionally rejects the CONNECT tunnel")
        } catch { /* expected: the proxy denied the tunnel */ }
        await fulfillment(of: [requestSeen], timeout: 3)
    }

    func testExternalConfigurationFollowsAppProxyButLoopbackStaysDirect() throws {
        let defaults = UserDefaults.standard
        let keys = [NetworkProxy.enabledKey, NetworkProxy.urlKey, NetworkProxy.bypassKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: NetworkProxy.enabledKey)
        defaults.set("http://127.0.0.1:45678", forKey: NetworkProxy.urlKey)
        let external = NetworkProxy.externalConfiguration()
        XCTAssertEqual(external.connectionProxyDictionary?["HTTPPort"] as? Int, 45678)
        XCTAssertEqual(external.connectionProxyDictionary?["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertTrue(NetworkProxy.directSession().configuration.connectionProxyDictionary?.isEmpty == true)
        defaults.set(false, forKey: NetworkProxy.enabledKey)
        XCTAssertTrue(NetworkProxy.externalConfiguration().connectionProxyDictionary?.isEmpty == true)
    }

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
