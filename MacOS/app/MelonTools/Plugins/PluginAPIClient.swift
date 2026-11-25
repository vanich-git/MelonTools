import Foundation

/// Where the plugin management API lives for one gateway generation. The port
/// and the management secret can change while the app is running, so the
/// client never caches either value.
struct PluginEndpoint: Equatable {
    let baseURL: URL
    let secret: String

    @MainActor
    static func current() -> PluginEndpoint {
        let gateway = CodexGatewayService.shared
        return PluginEndpoint(
            baseURL: URL(string: gateway.baseURL) ?? URL(string: "http://127.0.0.1:18317")!,
            secret: CodexGatewayService.managementSecret
        )
    }
}

struct PluginAPIError: LocalizedError {
    let status: Int
    let code: String
    let message: String

    var errorDescription: String? {
        if message.isEmpty { return "HTTP \(status)" }
        return message
    }
}

/// Thin async wrapper around the gateway management routes.
///
/// Store operations live under `/v8/management`; enable and config live under
/// `/v0/management`. That split is the engine's, not an accident, and mixing
/// them produces a 404 that looks like a missing plugin.
actor PluginAPIClient {
    private let session: URLSession

    init(session: URLSession = NetworkProxy.directSession()) {
        self.session = session
    }

    func installed(at endpoint: PluginEndpoint) async throws -> PluginInstalledResponse {
        let data = try await request(endpoint, path: "/v8/management/plugins")
        return try decode(data)
    }

    func store(at endpoint: PluginEndpoint) async throws -> PluginStoreResponse {
        let data = try await request(endpoint, path: "/v8/management/plugins/store")
        return try decode(data)
    }

    func install(
        id: String,
        version: String?,
        sourceID: String?,
        at endpoint: PluginEndpoint
    ) async throws -> PluginInstallResult {
        // Installing downloads a native library, which can legitimately take
        // minutes on a slow link; the other routes are local IPC.
        let components = try Self.installComponents(id: id, sourceID: sourceID)
        let path = components.string ?? "/v8/management/plugins/store/\(id)/install"
        var body: [String: Any] = [:]
        if let version, !version.isEmpty { body["version"] = version }
        let data = try await request(
            endpoint,
            path: path,
            method: "POST",
            body: body.isEmpty ? nil : try JSONSerialization.data(withJSONObject: body),
            timeout: Self.installTimeout
        )
        return try decode(data)
    }

    func remove(id: String, at endpoint: PluginEndpoint) async throws {
        _ = try await request(endpoint, path: "/v8/management/plugins/\(try Self.pathSegment(id))", method: "DELETE")
    }

    func setEnabled(id: String, enabled: Bool, at endpoint: PluginEndpoint) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        _ = try await request(
            endpoint,
            path: "/v0/management/plugins/\(try Self.pathSegment(id))/enabled",
            method: "PATCH",
            body: body
        )
    }

    func config(id: String, at endpoint: PluginEndpoint) async throws -> [String: PluginJSON] {
        let data = try await request(endpoint, path: "/v0/management/plugins/\(try Self.pathSegment(id))/config")
        return try decode(data)
    }

    func saveConfig(
        id: String,
        values: [String: PluginJSON],
        at endpoint: PluginEndpoint
    ) async throws {
        let body = try JSONEncoder().encode(values)
        _ = try await request(
            endpoint,
            path: "/v0/management/plugins/\(try Self.pathSegment(id))/config",
            method: "PUT",
            body: body
        )
    }

    // MARK: - Validation

    /// Requests take minutes when they download a native library and stay
    /// local otherwise. A single short timeout would kill installs mid-write.
    static let installTimeout: TimeInterval = 300

    /// Plugin ids travel inside URL paths and later become file names. Accept
    /// only the engine alphabet (`[A-Za-z0-9][A-Za-z0-9._-]{0,127}`) so a
    /// corrupted registry response cannot smuggle `..`, `/` or a query into
    /// the request path.
    static func pathSegment(_ id: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard let first = id.first, first.isLetter || first.isNumber,
              id.count <= 128,
              id.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw PluginAPIError(status: 0, code: "invalid_plugin_id", message: L("The plugin id is not valid."))
        }
        return id
    }

    private static func installComponents(id: String, sourceID: String?) throws -> URLComponents {
        var components = URLComponents()
        components.path = "/v8/management/plugins/store/\(try pathSegment(id))/install"
        if let sourceID, !sourceID.isEmpty {
            components.queryItems = [URLQueryItem(name: "source", value: sourceID)]
        }
        return components
    }

    // MARK: - Transport

    private func request(
        _ endpoint: PluginEndpoint,
        path: String,
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval = 45
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: endpoint.baseURL) else {
            throw PluginAPIError(status: 0, code: "invalid_url", message: "Invalid management URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PluginAPIError(status: 0, code: "no_response", message: L("The gateway did not answer."))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.parseError(data: data, status: http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PluginAPIError(
                status: 0,
                code: "decode_failed",
                message: L("The gateway returned an unexpected response.") + " " + error.localizedDescription
            )
        }
    }

    private static func parseError(data: Data, status: Int) -> PluginAPIError {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = object["error"] as? String ?? ""
            let message = object["message"] as? String ?? ""
            return PluginAPIError(status: status, code: code, message: message)
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PluginAPIError(status: status, code: "", message: text)
    }
}
