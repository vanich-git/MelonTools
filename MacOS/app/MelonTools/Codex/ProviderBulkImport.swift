import Foundation

/// Which engine auth file family a bulk-import entry belongs to.
enum ProviderKind: String, Equatable {
    case claude
    case antigravity
}

/// One Claude or Antigravity credential parsed from a Cockpit/CPA or
/// sub2api JSON export. The engine hot-reloads these files, so an import made
/// while the gateway is running needs no restart.
struct ProviderCredential {
    var kind: ProviderKind
    var email: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var projectID: String?
    var accountUUID: String?
    var organizationUUID: String?
    var organizationName: String?
    var expired: String?
    var expiresIn: Int?
    var timestamp: Int?
    var lastRefresh: String?

    /// Stable de-duplication key for entries in one JSON file.
    var dedupeKey: String {
        let identity = email?.lowercased()
            ?? accountUUID
            ?? projectID
            ?? refreshToken
            ?? accessToken
            ?? ""
        return "\(kind.rawValue):\(identity):\(organizationUUID ?? "")"
    }

    fileprivate var identityToken: String {
        refreshToken ?? accessToken ?? email ?? "provider"
    }
}

/// Parses and writes the non-OpenAI part of a bulk export. The Codex vault is
/// handled by `CodexBulkImport`; this type owns the engine auth files only.
enum ProviderBulkImport {
    struct Written: Equatable {
        var claude = 0
        var antigravity = 0
        var total: Int { claude + antigravity }
    }

    /// Map a sub2api/Cockpit platform name to a provider. Unknown platforms
    /// are skipped instead of being guessed.
    static func kind(forPlatform value: String) -> ProviderKind? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude", "anthropic", "claude-code", "claude_code":
            return .claude
        case "antigravity", "google-antigravity", "google_antigravity":
            return .antigravity
        default:
            return nil
        }
    }

    /// Parse one flat Cockpit/CPA entry or a sub2api entry with
    /// `credentials` / `tokens`.
    static func parse(_ object: [String: Any], kind: ProviderKind) -> ProviderCredential? {
        let flat = (object["credentials"] as? [String: Any])
            ?? (object["tokens"] as? [String: Any])
            ?? object

        let access = text(flat, ["access_token"]) ?? text(object, ["access_token"])
        let refresh = text(flat, ["refresh_token"]) ?? text(object, ["refresh_token"])
        guard access != nil || refresh != nil else { return nil }

        let email = text(flat, ["email"])
            ?? text(object, ["email"])
            ?? emailName(object)
            ?? emailName(flat)
        let projectID = text(flat, ["project_id", "projectId", "project"])
            ?? text(object, ["project_id", "projectId", "project"])
        let accountUUID = text(flat, ["account_uuid", "account_id", "chatgpt_account_id"])
            ?? text(object, ["account_uuid", "account_id", "chatgpt_account_id"])
        let organizationUUID = text(
            flat,
            ["organization_uuid", "organization_id", "organizationId", "org_id"]
        ) ?? text(
            object,
            ["organization_uuid", "organization_id", "organizationId", "org_id"]
        )
        let organizationName = text(flat, ["organization_name", "organizationName"])
            ?? text(object, ["organization_name", "organizationName"])

        let expiresIn = integer(flat, ["expires_in"]) ?? integer(object, ["expires_in"])
        let timestamp = integer(flat, ["timestamp"]) ?? integer(object, ["timestamp"])

        return ProviderCredential(
            kind: kind,
            email: email,
            accessToken: access,
            refreshToken: refresh,
            idToken: text(flat, ["id_token"]) ?? text(object, ["id_token"]),
            projectID: projectID,
            accountUUID: accountUUID,
            organizationUUID: organizationUUID,
            organizationName: organizationName,
            expired: expiry(flat) ?? expiry(object),
            expiresIn: expiresIn,
            timestamp: timestamp,
            lastRefresh: text(flat, ["last_refresh", "lastRefresh"])
                ?? text(object, ["last_refresh", "lastRefresh"])
        )
    }

    /// Write every credential into `directory`. An existing engine file with
    /// the same email is updated in place so device ids and other metadata
    /// written by the engine survive.
    static func write(_ credentials: [ProviderCredential], to directory: URL) throws -> Written {
        var written = Written()
        guard !credentials.isEmpty else { return written }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var seen = Set<String>()
        for credential in credentials {
            guard seen.insert(credential.dedupeKey).inserted else { continue }
            let url = targetURL(for: credential, in: directory)
            var object = existingObject(at: url) ?? [:]

            object["type"] = credential.kind.rawValue
            // An explicit import re-enables the account; a stale cooldown flag
            // must not keep freshly imported tokens out of rotation.
            object.removeValue(forKey: "disabled")
            set(credential.email, for: "email", in: &object)
            set(credential.accessToken, for: "access_token", in: &object)
            set(credential.refreshToken, for: "refresh_token", in: &object)
            set(credential.idToken, for: "id_token", in: &object)
            set(credential.projectID, for: "project_id", in: &object)
            set(credential.accountUUID, for: "account_uuid", in: &object)
            set(credential.organizationUUID, for: "organization_uuid", in: &object)
            set(credential.organizationName, for: "organization_name", in: &object)
            if let expired = effectiveExpired(credential) {
                object["expired"] = expired
            }
            if let expiresIn = credential.expiresIn {
                object["expires_in"] = expiresIn
            }
            object["timestamp"] = credential.timestamp ?? nowMillis
            object["last_refresh"] = credential.lastRefresh ?? iso8601(Date())

            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )

            switch credential.kind {
            case .claude: written.claude += 1
            case .antigravity: written.antigravity += 1
            }
        }
        return written
    }

    // MARK: - File placement

    private static func targetURL(for credential: ProviderCredential, in directory: URL) -> URL {
        if let email = credential.email,
           let existing = existingURL(for: credential, email: email, in: directory) {
            return existing
        }
        let identity = credential.email.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
            ?? shortHash(credential.identityToken)
        return directory.appendingPathComponent("\(credential.kind.rawValue)-\(identity).json")
    }

    private static func existingURL(
        for credential: ProviderCredential,
        email: String,
        in directory: URL
    ) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let wanted = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for name in names {
            guard !name.hasPrefix("._"), name.hasSuffix(".json") else { continue }
            guard isAuthFile(name, for: credential.kind) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let object = existingObject(at: url) else { continue }
            let existingEmail = (object["email"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard existingEmail == wanted else { continue }
            if let wantedOrg = credential.organizationUUID,
               let existingOrg = object["organization_uuid"] as? String,
               !existingOrg.isEmpty,
               wantedOrg != existingOrg {
                continue
            }
            return url
        }
        return nil
    }

    private static func isAuthFile(_ name: String, for kind: ProviderKind) -> Bool {
        switch kind {
        case .claude:
            return name.hasPrefix("claude-") && name.hasSuffix(".json")
        case .antigravity:
            return name == "antigravity.json"
                || (name.hasPrefix("antigravity-") && name.hasSuffix(".json"))
        }
    }

    private static func existingObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func set(_ value: String?, for key: String, in object: inout [String: Any]) {
        guard let value, !value.isEmpty else { return }
        object[key] = value
    }

    // MARK: - Value parsing

    private static func text(_ map: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = map[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func emailName(_ map: [String: Any]) -> String? {
        guard let name = text(map, ["name"]), name.contains("@") else { return nil }
        return name
    }

    private static func integer(_ map: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = map[key] as? NSNumber {
                return value.intValue
            }
            if let value = map[key] as? String, let number = Int(value) {
                return number
            }
        }
        return nil
    }

    private static func expiry(_ map: [String: Any]) -> String? {
        for key in ["expired", "expires_at", "expiresAt", "expire", "expiry"] {
            guard let value = map[key] else { continue }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let date = parseDate(trimmed) {
                    return iso8601(date)
                }
                if let epoch = Double(trimmed) {
                    return iso8601(epochDate(epoch))
                }
                return trimmed
            }
            if let number = value as? NSNumber {
                return iso8601(epochDate(number.doubleValue))
            }
        }
        return nil
    }

    private static func effectiveExpired(_ credential: ProviderCredential) -> String? {
        if let expired = credential.expired { return expired }
        guard let seconds = credential.expiresIn else { return nil }
        let base = credential.timestamp.map { epochDate(Double($0)) } ?? Date()
        return iso8601(base.addingTimeInterval(Double(seconds)))
    }

    private static func epochDate(_ value: Double) -> Date {
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static var nowMillis: Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - File names

    private static func sanitize(_ value: String) -> String {
        var invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        invalid.formUnion(.controlCharacters)
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { invalid.contains($0) ? "_" : String($0) }
            .joined()
        return String(cleaned.prefix(120))
    }

    private static func shortHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
