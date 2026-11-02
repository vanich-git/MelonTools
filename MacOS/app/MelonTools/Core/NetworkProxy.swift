import CFNetwork
import Foundation

/// Network proxy settings shared by the app and the embedded gateway.
///
/// The local gateway (`127.0.0.1`) is always direct. Only upstream requests
/// (OpenAI, providers, updates) use this proxy.
enum NetworkProxy {
    static let enabledKey = "networkProxyEnabled"
    static let urlKey = "networkProxyURL"
    static let bypassKey = "networkProxyBypass"
    static let defaultBypass = "127.0.0.1,localhost"

    private static let lock = NSLock()
    private static var cachedSession: (signature: String, session: URLSession)?
    private static var cachedDirectSession: URLSession?

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var configuredURL: String {
        let value = (UserDefaults.standard.string(forKey: urlKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return value.contains("://") ? value : "http://\(value)"
    }

    static var bypass: String {
        let value = UserDefaults.standard.string(forKey: bypassKey) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultBypass
            : value
    }

    /// Explicit proxy, or the system proxy when the URL field is empty.
    static func activeURL() -> String? {
        guard isEnabled else { return nil }
        let explicit = configuredURL
        if !explicit.isEmpty { return explicit }
        return systemProxyURL()
    }

    /// Session for external traffic. Rebuilt when the proxy settings change.
    static func session() -> URLSession {
        let signature = "\(isEnabled)|\(configuredURL)|\(bypass)|\(systemProxySignature())"
        lock.lock()
        defer { lock.unlock() }
        if let cachedSession, cachedSession.signature == signature {
            return cachedSession.session
        }
        let configuration = URLSessionConfiguration.default
        if isEnabled, let proxy = activeURL(), let dictionary = proxyDictionary(for: proxy, bypass: bypass) {
            configuration.connectionProxyDictionary = dictionary
        } else {
            // The switch is the single source of truth: without it, do not
            // silently inherit the macOS system proxy.
            configuration.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: configuration)
        cachedSession = (signature, session)
        return session
    }

    /// Session for loopback management/health calls: never use a proxy.
    static func directSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let cachedDirectSession { return cachedDirectSession }
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        cachedDirectSession = session
        return session
    }

    static func invalidate() {
        lock.lock()
        cachedSession = nil
        cachedDirectSession = nil
        lock.unlock()
    }

    // MARK: - System proxy

    static func systemSettings() -> [String: Any]? {
        guard let unmanaged = CFNetworkCopySystemProxySettings() else { return nil }
        return unmanaged.takeRetainedValue() as? [String: Any]
    }

    /// Resolve the system proxy for a representative upstream URL.
    ///
    /// `CFNetworkCopyProxiesForURL` does more than reading the static
    /// HTTP/HTTPS/SOCKS keys: macOS evaluates PAC files and proxy
    /// auto-discovery for the target URL and returns the concrete proxy. That
    /// matters because many proxy clients configure a PAC script only.
    static func systemProxyURL(for target: String = "https://chatgpt.com") -> String? {
        guard let settings = systemSettings(),
              let url = URL(string: target) else {
            return nil
        }
        let unmanaged = CFNetworkCopyProxiesForURL(url as CFURL, settings as CFDictionary)
        let proxies = unmanaged.takeRetainedValue() as? [[String: Any]] ?? []
        return proxyURL(from: proxies)
    }

    /// Map the first usable CFNetwork proxy entry to a URL. A `None` entry
    /// means the system decided this request goes direct.
    static func proxyURL(from proxies: [[String: Any]]) -> String? {
        for proxy in proxies {
            guard let type = proxy[kCFProxyTypeKey as String] as? String else { continue }
            if type == (kCFProxyTypeNone as String) { return nil }
            guard let host = proxy[kCFProxyHostNameKey as String] as? String,
                  !host.isEmpty,
                  let port = proxy[kCFProxyPortNumberKey as String] as? NSNumber else { continue }
            let scheme: String
            if type == (kCFProxyTypeSOCKS as String) {
                scheme = "socks5"
            } else if type == (kCFProxyTypeHTTPS as String) {
                scheme = "https"
            } else if type == (kCFProxyTypeHTTP as String) {
                scheme = "http"
            } else {
                continue
            }
            return "\(scheme)://\(host):\(port.intValue)"
        }
        return nil
    }

    private static func systemProxySignature() -> String {
        systemProxyURL() ?? ""
    }

    // MARK: - Dictionary

    static func proxyDictionary(for raw: String, bypass: String) -> [AnyHashable: Any]? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty else { return nil }
        let scheme = (url.scheme ?? "http").lowercased()
        let port = url.port ?? (scheme.hasPrefix("socks") ? 1080 : 8080)
        let user = (url.user ?? "").removingPercentEncoding ?? url.user ?? ""
        let password = (url.password ?? "").removingPercentEncoding ?? url.password ?? ""
        let exceptions = bypass
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var dictionary: [AnyHashable: Any] = [
            "ExceptionsList": exceptions,
        ]
        if scheme.hasPrefix("socks") {
            dictionary["SOCKSEnable"] = 1
            dictionary["SOCKSProxy"] = host
            dictionary["SOCKSPort"] = port
            if !user.isEmpty {
                dictionary["SOCKSUser"] = user
                dictionary["SOCKSPassword"] = password
            }
        } else {
            dictionary["HTTPEnable"] = 1
            dictionary["HTTPProxy"] = host
            dictionary["HTTPPort"] = port
            dictionary["HTTPSEnable"] = 1
            dictionary["HTTPSProxy"] = host
            dictionary["HTTPSPort"] = port
            if !user.isEmpty {
                dictionary["HTTPUser"] = user
                dictionary["HTTPPassword"] = password
                dictionary["HTTPSUser"] = user
                dictionary["HTTPSPassword"] = password
            }
        }
        return dictionary
    }
}
