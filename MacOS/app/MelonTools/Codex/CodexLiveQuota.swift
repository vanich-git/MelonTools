import Foundation

// MARK: - Management API shapes

/// One entry of `GET /v0/management/auth-files`. Only the fields the quota
/// guard needs are decoded; the engine may add more.
struct CodexManagementAuthFile: Decodable, Equatable {
    var name: String
    var authIndex: String?
    var disabled: Bool
    var email: String?
    var provider: String?
    var quota: CodexManagementQuota?

    enum CodingKeys: String, CodingKey {
        case name
        case authIndex = "auth_index"
        case disabled
        case email
        case provider
        case quota
    }
}

struct CodexManagementQuota: Decodable, Equatable {
    var observedAt: Date?
    var signals: [String: String]

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case signals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stamp = try container.decodeIfPresent(String.self, forKey: .observedAt)
        observedAt = stamp.flatMap(ISODate.parse)
        signals = (try container.decodeIfPresent([String: String].self, forKey: .signals)) ?? [:]
    }
}

struct CodexManagementSnapshot: Equatable {
    var files: [CodexManagementAuthFile]
    var observedAt: Date?

    func file(named name: String, authIndex: String? = nil) -> CodexManagementAuthFile? {
        if let authIndex, !authIndex.isEmpty,
           let match = files.first(where: { $0.authIndex == authIndex }) {
            return match
        }
        return files.first { $0.name == name }
    }

    var codexFiles: [CodexManagementAuthFile] {
        files.filter { ($0.provider ?? "").lowercased() == "codex" || $0.name.hasPrefix("codex-") }
    }
}

// MARK: - Live signal parsing

/// A point reading built from the gateway's passive Codex headers. The
/// gateway records these headers on every upstream response, so the app can
/// see quota movement in 1–2 seconds instead of waiting for `/wham/usage`.
struct CodexLiveQuotaReading: Equatable {
    var quota: CodexQuota
    var observedAt: Date
}

enum CodexLiveQuota {
    /// How long a passive signal stays believable for route decisions. The
    /// gateway refreshes it on each request; when traffic stops the last
    /// reading is still close enough for a short while.
    static let maxSignalAge: TimeInterval = 120

    static func parse(signals: [String: String], observedAt: Date) -> CodexLiveQuotaReading? {
        guard !signals.isEmpty else { return nil }
        let lookup = signalLookup(signals)
        var quota = CodexQuota()
        quota.fetchedAt = observedAt

        quota.hourlyRemainingPercent = remaining(lookup["x-codex-primary-used-percent"])
        quota.weeklyRemainingPercent = remaining(lookup["x-codex-secondary-used-percent"])
        quota.hourlyWindowMinutes = minutes(lookup["x-codex-primary-window-minutes"])
        quota.weeklyWindowMinutes = minutes(lookup["x-codex-secondary-window-minutes"])
        quota.hourlyResetAt = resetDate(
            at: lookup["x-codex-primary-reset-at"],
            after: lookup["x-codex-primary-reset-after-seconds"],
            observedAt: observedAt
        )
        quota.weeklyResetAt = resetDate(
            at: lookup["x-codex-secondary-reset-at"],
            after: lookup["x-codex-secondary-reset-after-seconds"],
            observedAt: observedAt
        )
        quota.planType = lookup["x-codex-plan-type"].flatMap { $0.isEmpty ? nil : $0 }

        guard quota.hourlyRemainingPercent != nil || quota.weeklyRemainingPercent != nil else {
            return nil
        }
        return CodexLiveQuotaReading(quota: quota, observedAt: observedAt)
    }

    static func isFresh(_ observedAt: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= -5 && age <= maxSignalAge
    }

    /// Clone of the cached quota with only the fields the live headers own.
    /// Model availability, credits and reset-credit counts stay intact.
    static func merging(_ reading: CodexLiveQuotaReading, into cached: CodexQuota?) -> CodexQuota {
        var merged = cached ?? CodexQuota()
        if let value = reading.quota.hourlyRemainingPercent { merged.hourlyRemainingPercent = value }
        if let value = reading.quota.weeklyRemainingPercent { merged.weeklyRemainingPercent = value }
        if let value = reading.quota.hourlyResetAt { merged.hourlyResetAt = value }
        if let value = reading.quota.weeklyResetAt { merged.weeklyResetAt = value }
        if let value = reading.quota.hourlyWindowMinutes { merged.hourlyWindowMinutes = value }
        if let value = reading.quota.weeklyWindowMinutes { merged.weeklyWindowMinutes = value }
        if let value = reading.quota.planType { merged.planType = value }
        merged.hourlyWindowPresent = reading.quota.hourlyRemainingPercent != nil
        merged.weeklyWindowPresent = reading.quota.weeklyRemainingPercent != nil
        merged.fetchedAt = reading.observedAt
        return merged
    }

    /// Compare only the fields owned by passive headers. `fetchedAt`,
    /// `rawJSON` and model availability change on every read and must not
    /// invalidate every observing SwiftUI view.
    static func liveValuesDiffer(_ lhs: CodexQuota?, _ rhs: CodexQuota?) -> Bool {
        guard let lhs, let rhs else { return lhs != nil || rhs != nil }
        return lhs.planType != rhs.planType
            || lhs.hourlyRemainingPercent != rhs.hourlyRemainingPercent
            || lhs.weeklyRemainingPercent != rhs.weeklyRemainingPercent
            || lhs.hourlyResetAt != rhs.hourlyResetAt
            || lhs.weeklyResetAt != rhs.weeklyResetAt
            || lhs.hourlyWindowMinutes != rhs.hourlyWindowMinutes
            || lhs.weeklyWindowMinutes != rhs.weeklyWindowMinutes
            || lhs.hourlyWindowPresent != rhs.hourlyWindowPresent
            || lhs.weeklyWindowPresent != rhs.weeklyWindowPresent
    }

    private static func signalLookup(_ signals: [String: String]) -> [String: String] {
        var lookup: [String: String] = [:]
        for (key, value) in signals {
            lookup[key.lowercased()] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lookup
    }

    private static func remaining(_ used: String?) -> Double? {
        guard let used, let value = Double(used) else { return nil }
        return max(0, min(100, 100 - value))
    }

    private static func minutes(_ raw: String?) -> Int? {
        guard let raw, let value = Double(raw) else { return nil }
        return Int(value.rounded())
    }

    private static func resetDate(at raw: String?, after: String?, observedAt: Date) -> Date? {
        if let raw, let unix = Double(raw), unix > 0 {
            return Date(timeIntervalSince1970: unix)
        }
        if let after, let seconds = Double(after), seconds >= 0 {
            return observedAt.addingTimeInterval(seconds)
        }
        return nil
    }
}

// MARK: - Management calls

extension CodexGatewayService {
    /// Read auth files and their passive quota observations. Short timeout:
    /// this runs on the live guard path and must never stall the scheduler.
    func fetchManagementAuths(timeout: TimeInterval = 2.5) async -> CodexManagementSnapshot? {
        let url = URL(string: "\(baseURL)/v0/management/auth-files")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(Self.managementSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let files = (object["files"] as? [[String: Any]]) ?? []
            var decoded: [CodexManagementAuthFile] = []
            for raw in files {
                let entry = try JSONSerialization.data(withJSONObject: raw)
                if let file = try? JSONDecoder().decode(CodexManagementAuthFile.self, from: entry) {
                    decoded.append(file)
                }
            }
            let stamp = (object["observed_at"] as? String).flatMap(ISODate.parse)
            return CodexManagementSnapshot(files: decoded, observedAt: stamp)
        } catch {
            return nil
        }
    }

    /// Toggle one auth file through the management API. The call is verified
    /// by reading `disabled` back, so a 200 that did not persist is a failure.
    func setManagementAuthDisabled(
        name: String,
        authIndex: String?,
        disabled: Bool,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let url = URL(string: "\(baseURL)/v0/management/auth-files/status")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(Self.managementSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["name": name, "disabled": disabled]
        if let authIndex, !authIndex.isEmpty { body["auth_index"] = authIndex }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return false }
        request.httpBody = payload
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            guard let snapshot = await fetchManagementAuths(timeout: timeout),
                  let file = snapshot.file(named: name, authIndex: authIndex) else {
                return false
            }
            return file.disabled == disabled
        } catch {
            return false
        }
    }
}
