import Foundation

/// Bulk account import for Cockpit/CPA and sub2api JSON exports.
///
/// Both formats carry the OAuth triple (`access_token`, `refresh_token`,
/// `id_token`) plus the ChatGPT account id. They differ only in nesting:
/// Cockpit uses a flat array, sub2api wraps the same fields in
/// `accounts[].credentials`. Claude and Antigravity entries from the same
/// export are parsed here and written by `ProviderBulkImport`.
enum CodexBulkImport {
    struct Result {
        var accounts: [CodexAccount]
        var providers: [ProviderCredential]
        var skipped: Int
    }

    enum ImportError: LocalizedError {
        case invalidJSON
        case unsupportedFormat
        case noAccounts

        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "The file is not valid JSON."
            case .unsupportedFormat: return "Use a Cockpit/CPA array or a sub2api-data export."
            case .noAccounts: return "No accounts with tokens were found."
            }
        }
    }

    static func parse(_ text: String) throws -> Result {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportError.invalidJSON
        }
        var objects: [[String: Any]] = []
        if let array = root as? [[String: Any]] {
            objects = array
        } else if let object = root as? [String: Any] {
            if let accounts = object["accounts"] as? [[String: Any]] {
                objects = accounts
            } else if object["access_token"] != nil || object["tokens"] != nil {
                // A single saved auth.json is still a valid one-account import.
                objects = [object]
            } else {
                throw ImportError.unsupportedFormat
            }
        } else {
            throw ImportError.invalidJSON
        }

        var accounts: [CodexAccount] = []
        var providers: [ProviderCredential] = []
        var seen: Set<String> = []
        var seenProviders: Set<String> = []
        var skipped = 0
        for object in objects {
            let platform = (object["platform"] as? String)
                ?? (object["provider"] as? String)
                ?? ""
            let declaredType = object["type"] as? String ?? ""
            let kind = ProviderBulkImport.kind(forPlatform: platform)
                ?? (platform.isEmpty ? ProviderBulkImport.kind(forPlatform: declaredType) : nil)

            if let kind {
                guard let credential = ProviderBulkImport.parse(object, kind: kind) else {
                    skipped += 1
                    continue
                }
                guard seenProviders.insert(credential.dedupeKey).inserted else {
                    skipped += 1
                    continue
                }
                providers.append(credential)
                continue
            }

            // sub2api may contain platforms this importer does not own.
            if !platform.isEmpty,
               platform.lowercased() != "openai",
               platform.lowercased() != "codex" {
                skipped += 1
                continue
            }
            guard let account = parseAccount(object) else {
                skipped += 1
                continue
            }
            let key = (account.accountId ?? account.email ?? account.id).lowercased()
            if !key.isEmpty, !seen.insert(key).inserted {
                skipped += 1
                continue
            }
            accounts.append(account)
        }
        guard !accounts.isEmpty || !providers.isEmpty else { throw ImportError.noAccounts }
        return Result(accounts: accounts, providers: providers, skipped: skipped)
    }

    private static func parseAccount(_ object: [String: Any]) -> CodexAccount? {
        let credentials = object["credentials"] as? [String: Any]
        let nestedTokens = object["tokens"] as? [String: Any]
        let flat = credentials ?? nestedTokens ?? object

        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = flat[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
            return nil
        }

        let access = string(["access_token"])
        let refresh = string(["refresh_token"])
        guard access != nil || refresh != nil else { return nil }
        let idToken = string(["id_token"])
        let accountID = string(["chatgpt_account_id", "account_id"])
        let email = string(["email"])
            ?? (object["email"] as? String)
            ?? ((object["name"] as? String)?.contains("@") == true ? object["name"] as? String : nil)

        var tokens = CodexTokens(
            id_token: idToken,
            access_token: access,
            refresh_token: refresh,
            account_id: accountID
        )
        let claims = JWT.codexClaims(idToken: idToken)
        tokens.account_id = claims.accountId ?? tokens.account_id

        var account = CodexAccount(tokens: tokens)
        account.email = claims.email ?? email
        account.planType = claims.planType ?? object["plan_type"] as? String
        account.accountId = claims.accountId ?? accountID
        account.userId = claims.userId
        account.subscriptionActiveUntil = claims.subscriptionUntil
        account.lastRefresh = object["last_refresh"] as? String
        return account
    }
}
