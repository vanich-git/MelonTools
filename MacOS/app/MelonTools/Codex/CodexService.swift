import Foundation
import CryptoKit
import Security

/// Codex OAuth (device flow + browser PKCE), token refresh, and quota endpoints.
/// Behavior re-implemented from the cockpit-tools spec (endpoints verified there).
enum CodexService {

    // MARK: - Constants

    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    static let deviceUserCodeEndpoint = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    static let deviceTokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    static let deviceVerificationURL = "https://auth.openai.com/codex/device"
    static let deviceRedirectURI = "https://auth.openai.com/deviceauth/callback"
    static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let subscriptionEndpoint = URL(string: "https://chatgpt.com/backend-api/subscriptions")!
    static let resetCreditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let consumeResetCreditEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
    /// Official Codex client model catalog. This is the list the Codex desktop
    /// app itself uses; it is not the same as the gateway `/v1/models` list.
    static let modelsEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/models")!
    /// Keep this in step with the Codex client version used by the app. The
    /// endpoint uses it to decide which model entries are visible.
    static let modelsClientVersion = "0.159.0"
    static let modelsUserAgent = "codex_cli_rs/0.159.0 (Mac OS 26.3.1; arm64) iTerm.app/3.6.9"
    static let userAgent = "Codex Desktop (macOS; arm64)"
    /// The subscriptions route expects the web app's header set (verified in
    /// cockpit-tools): target-path/route + Referer + a browser user agent.
    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
    static let originator = "Codex Desktop"

    enum CodexError: Error, LocalizedError {
        case http(Int, String)
        case decoding(String)
        case loginPending
        case refreshUnavailable
        case notLoggedIn
        case loopbackUnavailable
        /// OpenAI rotates refresh tokens: once a token was exchanged, the old
        /// one is dead. Retrying cannot succeed; the user has to sign in again.
        case reloginRequired

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
            case .decoding(let detail): return "Decode error: \(detail)"
            case .loginPending: return "Login still pending"
            case .refreshUnavailable: return "No refresh token available"
            case .notLoggedIn: return "~/.codex/auth.json not found — log in with the Codex CLI first, or use device login."
            case .loopbackUnavailable: return L("Local ports 1455 and 1457 are busy — close the other login attempt and try again.")
            case .reloginRequired: return L("The refresh token was revoked — sign in to this account again.")
            }
        }
    }

    // MARK: - Device flow

    struct DeviceLoginSession {
        let deviceAuthId: String
        let userCode: String
        let interval: Int
        let verificationURL: String
    }

    static func startDeviceLogin() async throws -> DeviceLoginSession {
        var request = URLRequest(url: deviceUserCodeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientId])

        let (data, response) = try await NetworkProxy.session().data(for: request)
        try ensureOK(response, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceAuthId = obj["device_auth_id"] as? String,
              let userCode = obj["user_code"] as? String else {
            throw CodexError.decoding("device usercode response missing fields")
        }
        let interval = (obj["interval"] as? Int) ?? 5
        return DeviceLoginSession(
            deviceAuthId: deviceAuthId,
            userCode: userCode,
            interval: interval,
            verificationURL: deviceVerificationURL
        )
    }

    /// One poll attempt. Returns tokens on success, nil while still pending.
    static func pollDeviceLogin(session: DeviceLoginSession) async throws -> CodexTokens? {
        var request = URLRequest(url: deviceTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": session.deviceAuthId,
            "user_code": session.userCode,
        ])

        let (data, response) = try await NetworkProxy.session().data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexError.http(-1, "no response") }

        switch http.statusCode {
        case 200:
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = obj["authorization_code"] as? String,
                  let verifier = obj["code_verifier"] as? String else {
                throw CodexError.decoding("device token response missing fields")
            }
            return try await exchangeCode(code: code, verifier: verifier, redirectURI: deviceRedirectURI)
        case 403, 404:
            return nil // keep polling
        default:
            throw CodexError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Browser login (PKCE + loopback)

    static let authorizeEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let browserScope = "openid profile email offline_access"

    struct PKCE {
        let verifier: String
        let challenge: String
        let state: String
    }

    /// PKCE verifier/challenge (S256) + state, both base64url of 32/16 random bytes.
    static func makePKCE() -> PKCE? {
        var verifierBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes) == errSecSuccess else { return nil }
        var stateBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes) == errSecSuccess else { return nil }
        let verifier = Data(verifierBytes).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = Data(stateBytes).base64URLEncodedString()
        return PKCE(verifier: verifier, challenge: challenge, state: state)
    }

    /// The authorize URL that the official CLI opens in the browser.
    static func authorizationURL(challenge: String, state: String, redirectURI: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: browserScope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return components.url!
    }

    /// Exchange an authorization code (device flow or browser PKCE) for tokens.
    static func exchangeCode(code: String, verifier: String, redirectURI: String) async throws -> CodexTokens {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await NetworkProxy.session().data(for: request)
        try ensureOK(response, data)
        return try parseTokenResponse(data)
    }

    // MARK: - Refresh

    static func refreshTokens(_ account: CodexAccount) async throws -> CodexTokens {
        guard let refreshToken = account.tokens.refresh_token, !refreshToken.isEmpty else {
            throw CodexError.refreshUnavailable
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(originator, forHTTPHeaderField: "originator")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ], options: [])

        let (data, response) = try await NetworkProxy.session().data(for: request)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 401,
           Self.isRefreshTokenReused(data) {
            throw CodexError.reloginRequired
        }
        try ensureOK(response, data)

        var tokens = try parseTokenResponse(data)
        // Fallbacks per the official client behavior.
        if tokens.id_token == nil { tokens.id_token = account.tokens.id_token }
        if tokens.refresh_token == nil { tokens.refresh_token = refreshToken }
        return tokens
    }

    /// The token endpoint answers `401 refresh_token_reused` after another
    /// client exchanged the same rotating token. Only a new login helps, so
    /// the caller must not retry the request.
    static func isRefreshTokenReused(_ data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8) else { return false }
        return body.contains("refresh_token_reused")
    }

    /// Returns a token guaranteed fresh (refreshes when within 5 min of expiry).
    static func freshTokens(for account: CodexAccount) async throws -> CodexTokens {
        if !account.needsRefresh, let access = account.tokens.access_token, !access.isEmpty {
            return account.tokens
        }
        return try await refreshTokens(account)
    }

    private static func parseTokenResponse(_ data: Data) throws -> CodexTokens {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.decoding("token response not an object")
        }
        return CodexTokens(
            id_token: obj["id_token"] as? String,
            access_token: obj["access_token"] as? String,
            refresh_token: obj["refresh_token"] as? String,
            account_id: obj["account_id"] as? String
        )
    }

    // MARK: - Quota

    /// GET https://chatgpt.com/backend-api/wham/usage
    /// Fresh subscription info from the backend (`active_until`). The id_token
    /// claim alone goes stale after plan changes, so the store re-reads this
    /// every 30 minutes. The edge sometimes blocks URLSession (403) while the
    /// system curl passes, so both are tried before giving up.
    static func fetchSubscription(account: CodexAccount) async throws -> (plan: String?, activeUntil: String?) {
        let tokens = try await freshTokens(for: account)
        guard let access = tokens.access_token else { throw CodexError.refreshUnavailable }
        let accountId = safeAccountId(effectiveAccountId(account, tokens: tokens))
        var components = URLComponents(url: subscriptionEndpoint, resolvingAgainstBaseURL: false)
        if let accountId, !accountId.isEmpty {
            components?.queryItems = [URLQueryItem(name: "account_id", value: accountId)]
        }
        guard let url = components?.url else { throw CodexError.decoding("subscriptions url") }
        return try await urlSessionSubscription(url: url, token: access, accountId: accountId)
    }

    private static func urlSessionSubscription(url: URL, token: String, accountId: String?) async throws -> (plan: String?, activeUntil: String?) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("/backend-api/subscriptions", forHTTPHeaderField: "x-openai-target-path")
        request.setValue("/backend-api/subscriptions", forHTTPHeaderField: "x-openai-target-route")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await NetworkProxy.session().data(for: request)
        try ensureOK(response, data)
        return try parseSubscription(data)
    }

    private static func parseSubscription(_ data: Data) throws -> (plan: String?, activeUntil: String?) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.decoding("subscriptions response not an object")
        }
        let plan = (obj["subscription_plan"] as? String) ?? (obj["plan_type"] as? String)
        let until = (obj["active_until"] as? String) ?? (obj["expires_at"] as? String)
        return (plan, until)
    }

    /// GET the official Codex client model catalog and return its `models`
    /// array. A 401 rotates the access token once, like the quota path.
    static func fetchModelCatalog(
        account: CodexAccount
    ) async throws -> (models: [[String: Any]], tokens: CodexTokens) {
        let tokens = try await freshTokens(for: account)
        do {
            return (try await fetchModelCatalog(account: account, tokens: tokens), tokens)
        } catch CodexError.http(401, _) {
            let refreshed = try await refreshTokens(account)
            var retryAccount = account
            retryAccount.tokens = refreshed
            return (
                try await fetchModelCatalog(account: retryAccount, tokens: refreshed),
                refreshed
            )
        }
    }

    private static func fetchModelCatalog(
        account: CodexAccount,
        tokens: CodexTokens
    ) async throws -> [[String: Any]] {
        guard let access = tokens.access_token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty else {
            throw CodexError.refreshUnavailable
        }
        var components = URLComponents(url: modelsEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_version", value: modelsClientVersion),
        ]
        guard let url = components?.url else {
            throw CodexError.decoding("models url")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "Originator")
        request.setValue(modelsUserAgent, forHTTPHeaderField: "User-Agent")
        if let accountId = safeAccountId(effectiveAccountId(account, tokens: tokens)),
           !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "Chatgpt-Account-Id")
        }
        let (data, response) = try await NetworkProxy.session().data(for: request)
        try ensureOK(response, data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]],
              !models.isEmpty else {
            throw CodexError.decoding("models response has no models")
        }
        return models
    }

    /// Refresh-credit records for the 5-hour window: how many are available,
    /// when the nearest one expires, and the individual records with ids.
    static func fetchResetCredits(account: CodexAccount) async throws -> ResetCreditDetails {
        let tokens = try await freshTokens(for: account)
        guard let access = tokens.access_token else { throw CodexError.refreshUnavailable }
        var request = URLRequest(url: resetCreditsEndpoint)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(originator, forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = safeAccountId(effectiveAccountId(account, tokens: tokens)), !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await NetworkProxy.session().data(for: request)
        try ensureOK(response, data)
        return try parseResetCredits(data)
    }

    struct ResetCreditDetails: Equatable {
        var available: Int?
        var nextExpiry: Date?
        var credits: [CodexResetCredit]
    }

    enum ResetCreditOutcome: Equatable {
        case reset
        case nothingToReset
        case noCredit
        case alreadyRedeemed
    }

    /// Parse the read-only reset-credit response. The endpoint has returned
    /// both flat and `data`-nested shapes.
    static func parseResetCredits(_ data: Data) throws -> ResetCreditDetails {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.decoding("reset credits response not an object")
        }
        let nested = obj["data"] as? [String: Any]
        let available = (obj["available_count"] as? Int)
            ?? (obj["availableCount"] as? Int)
            ?? (nested?["available_count"] as? Int)
            ?? (nested?["availableCount"] as? Int)
        let records = (obj["credits"] as? [[String: Any]])
            ?? (nested?["credits"] as? [[String: Any]])
            ?? []
        var credits: [CodexResetCredit] = []
        for record in records {
            let status = (record["status"] as? String)?.lowercased()
            // Only spendable records can be redeemed.
            guard status == nil || status == "available" || status == "granted" else { continue }
            guard let id = (record["id"] as? String) ?? (record["credit_id"] as? String),
                  !id.isEmpty else { continue }
            credits.append(CodexResetCredit(
                id: id,
                status: status,
                title: record["title"] as? String,
                grantedAt: resetCreditDate(record["granted_at"] ?? record["grantedAt"]),
                expiresAt: resetCreditDate(record["expires_at"] ?? record["expiresAt"] ?? record["expiry"])
            ))
        }
        let nextExpiry = credits.compactMap(\.expiresAt).min()
        let resolvedAvailable = available ?? (records.isEmpty ? nil : credits.count)
        return ResetCreditDetails(available: resolvedAvailable, nextExpiry: nextExpiry, credits: credits)
    }

    /// Redeem one banked reset. `redeem_request_id` makes the request
    /// idempotent; the nearest-expiring credit is passed when its id is known.
    static func consumeResetCredit(account: CodexAccount, creditId: String?) async throws -> ResetCreditOutcome {
        let tokens = try await freshTokens(for: account)
        guard let access = tokens.access_token else { throw CodexError.refreshUnavailable }
        var request = URLRequest(url: consumeResetCreditEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(originator, forHTTPHeaderField: "originator")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accountId = safeAccountId(effectiveAccountId(account, tokens: tokens)), !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        var body: [String: String] = ["redeem_request_id": UUID().uuidString.lowercased()]
        if let creditId, !creditId.isEmpty {
            body["credit_id"] = creditId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await NetworkProxy.session().data(for: request)
        try ensureOK(response, data)
        return try parseResetCreditOutcome(data)
    }

    static func parseResetCreditOutcome(_ data: Data) throws -> ResetCreditOutcome {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.decoding("reset response not an object")
        }
        let nested = obj["data"] as? [String: Any]
        let raw = (obj["outcome"] as? String)
            ?? (obj["code"] as? String)
            ?? (nested?["outcome"] as? String)
            ?? (nested?["code"] as? String)
        switch raw {
        case "reset": return .reset
        case "nothing_to_reset", "nothingToReset": return .nothingToReset
        case "no_credit", "noCredit": return .noCredit
        case "already_redeemed", "alreadyRedeemed": return .alreadyRedeemed
        default: throw CodexError.decoding("unexpected reset outcome: \(raw ?? "missing")")
        }
    }

    /// Reset-credit timestamps arrive as ISO strings, Unix seconds or millis.
    private static let resetCreditISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func resetCreditDate(_ value: Any?) -> Date? {
        if let string = value as? String {
            return resetCreditISO.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        if let number = value as? Double {
            let seconds = number > 1_000_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        if let number = value as? Int {
            return resetCreditDate(Double(number))
        }
        return nil
    }

    /// ChatGPT account ids are UUID-like; anything else must not reach the
    /// backend URL or the curl header (injection guard).
    private static func safeAccountId(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }

    /// First non-empty account id from the account record, the token payload
    /// and the id_token claims. The subscriptions endpoint rejects requests
    /// without one (HTTP 400).
    private static func effectiveAccountId(_ account: CodexAccount, tokens: CodexTokens) -> String? {
        let candidates = [account.accountId, tokens.account_id, JWT.codexClaims(idToken: tokens.id_token).accountId]
        return candidates.first { $0 != nil && !$0!.isEmpty } ?? nil
    }

    static func fetchQuota(account: CodexAccount) async throws -> (quota: CodexQuota, tokens: CodexTokens) {
        let tokens = try await freshTokens(for: account)
        do {
            return (try await fetchQuota(account: account, tokens: tokens), tokens)
        } catch CodexError.http(401, _) {
            // The provider can revoke a token before its JWT expiry. Rotate it
            // once, then retry the quota request. The caller persists the
            // returned tokens with the quota so a reset probe does not loop.
            let refreshed = try await refreshTokens(account)
            var retryAccount = account
            retryAccount.tokens = refreshed
            return (try await fetchQuota(account: retryAccount, tokens: refreshed), refreshed)
        }
    }

    private static func fetchQuota(account: CodexAccount, tokens: CodexTokens) async throws -> CodexQuota {
        guard let access = tokens.access_token else { throw CodexError.refreshUnavailable }

        var request = URLRequest(url: usageEndpoint)
        request.timeoutInterval = 12
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(originator, forHTTPHeaderField: "originator")
        if let accountId = safeAccountId(effectiveAccountId(account, tokens: tokens)), !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await NetworkProxy.session().data(for: request)
        try ensureOK(response, data)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.decoding("usage response not an object")
        }

        var quota = CodexQuota()
        quota.fetchedAt = Date()
        quota.rawJSON = String(data: data, encoding: .utf8)
        quota.planType = obj["plan_type"] as? String

        if let rateLimit = obj["rate_limit"] as? [String: Any] {
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                quota.hourlyWindowPresent = true
                quota.hourlyRemainingPercent = remainingPercent(primary)
                quota.hourlyResetAt = resetDate(primary)
                quota.hourlyWindowMinutes = windowMinutes(primary)
            } else {
                quota.hourlyWindowPresent = false
                quota.hourlyRemainingPercent = 100
            }
            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                quota.weeklyWindowPresent = true
                quota.weeklyRemainingPercent = remainingPercent(secondary)
                quota.weeklyResetAt = resetDate(secondary)
                quota.weeklyWindowMinutes = windowMinutes(secondary)
            } else {
                quota.weeklyWindowPresent = false
                quota.weeklyRemainingPercent = 100
            }
        }

        if let credits = obj["rate_limit_reset_credits"] as? [String: Any] {
            quota.resetCreditsAvailable = (credits["available_count"] as? Int) ?? (credits["availableCount"] as? Int)
        }

        if let credits = obj["credits"] as? [String: Any] {
            quota.hasCredits = credits["has_credits"] as? Bool
            quota.unlimitedCredits = credits["unlimited"] as? Bool
            quota.creditsBalance = credits["balance"] as? String
        }

        if let modelUsage = obj["model_usage"] as? [String: Any] {
            var list: [CodexModelAvailability] = []
            for (model, raw) in modelUsage {
                guard let info = raw as? [String: Any] else { continue }
                list.append(CodexModelAvailability(
                    model: model,
                    available: (info["available"] as? Bool) ?? false,
                    availableAt: info["available_at"] as? String,
                    creditsWouldEnable: info["credits_would_enable"] as? Bool
                ))
            }
            quota.modelAvailability = list.sorted { $0.model < $1.model }
        }

        return quota
    }

    private static func remainingPercent(_ window: [String: Any]) -> Double? {
        if let used = window["used_percent"] as? Double { return max(0, min(100, 100 - used)) }
        if let used = window["used_percent"] as? Int { return max(0, min(100, 100 - Double(used))) }
        return nil
    }

    private static func resetDate(_ window: [String: Any]) -> Date? {
        if let resetAt = window["reset_at"] as? TimeInterval {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let after = window["reset_after_seconds"] as? TimeInterval {
            return Date().addingTimeInterval(after)
        }
        return nil
    }

    private static func windowMinutes(_ window: [String: Any]) -> Int? {
        guard let seconds = window["limit_window_seconds"] as? TimeInterval else { return nil }
        return Int(ceil(seconds / 60))
    }

    // MARK: - Helpers

    private static func ensureOK(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw CodexError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

extension Data {
    /// base64url without padding (RFC 7636 style).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
