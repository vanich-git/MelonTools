import Foundation

/// Redacted diagnostics for support. Contains versions, paths, file sizes,
/// gateway/route state and short log tails. Tokens, API keys, management
/// secrets, passwords and auth-file contents are never included.
@MainActor
enum SupportBundleService {
    static func export(to url: URL) throws {
        let object = try makeObject()
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try SecureFile.write(data, to: url)
    }

    static func makeObject() throws -> [String: Any] {
        let gateway = CodexGatewayService.shared
        let store = CodexStore.shared
        let fm = FileManager.default
        let info = Bundle.main.infoDictionary ?? [:]
        let support = CodexStore.supportDir
        let logURL = URL(fileURLWithPath: gateway.logPath)
        let configURL = URL(fileURLWithPath: gateway.configPath)
        let authDir = CodexGatewayService.authDir

        var result: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "app": [
                "version": info["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": info["CFBundleVersion"] as? String ?? "unknown",
                "bundle": Bundle.main.bundleIdentifier ?? "unknown",
            ],
            "system": [
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": architecture(),
            ],
            "gateway": [
                "running": gateway.isRunning,
                "port": gateway.port,
                "baseURL": gateway.baseURL,
                "engine": gatewayEnginePath(),
                "requestsLastMinute": gateway.requestsLastMinute,
                "logBytes": fileSize(logURL),
                "configBytes": fileSize(configURL),
            ],
            "accounts": [
                "count": store.accounts.count,
                "blocked": store.accounts.filter { $0.quotaBlock != nil }.count,
                "quotaErrors": store.accounts.filter { $0.quotaError != nil }.count,
                "authFiles": (try? fm.contentsOfDirectory(atPath: authDir.path).count) ?? 0,
                "quarantines": quarantineCount(in: support),
            ],
            "paths": [
                "support": support.path,
                "config": configURL.path,
                "log": logURL.path,
                "auths": authDir.path,
            ],
            "config": redact(readHead(configURL, limit: 64 * 1024)),
            "logTail": redact(readTail(logURL, limit: 32 * 1024)),
            "permissions": permissions(at: support),
        ]
        if let compose = composerState() {
            result["composer"] = compose
        }
        return result
    }

    private static func gatewayEnginePath() -> String {
        CodexGatewayService.locateBinary() ?? "missing"
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func quarantineCount(in support: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        return names.filter { $0.hasPrefix("accounts.corrupt.") }.count
    }

    private static func permissions(at url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return String(format: "%03o", (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0)
    }

    private static func readHead(_ url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func readTail(_ url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(limit) ? size - UInt64(limit) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Remove common secret shapes from log/config text before it leaves the
    /// machine. The bundle intentionally contains no auth-file bodies.
    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var value = text
        let patterns = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[redacted]"),
            (#"(?i)((?:api[_-]?key|token|secret|password|management-secret)\s*[:=]\s*)[^\s"']+"#, "$1[redacted]"),
            (#"sk-[A-Za-z0-9_-]{8,}"#, "[redacted]"),
            (#"melon-[A-Za-z0-9_-]{8,}"#, "[redacted]"),
            (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, "[redacted]"),
        ]
        for (pattern, replacement) in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return value
    }

    private static func composerState() -> [String: Any]? {
        let bridge = ComposerBridge.shared
        return [
            "enabled": bridge.enabled,
            "status": String(describing: bridge.status),
            "injectedPages": bridge.injectedPages,
        ]
    }
}
