import Foundation

// MARK: - JSON value

/// Small JSON tree used for plugin configuration. Plugin-owned config is
/// intentionally schemaless: the host forwards whatever the plugin metadata
/// declares, and unknown keys must survive a round trip through the editor.
enum PluginJSON: Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([PluginJSON])
    case object([String: PluginJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PluginJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PluginJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int(value)
        default: return nil
        }
    }

    var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var isEmpty: Bool {
        switch self {
        case .null: return true
        case .string(let value): return value.isEmpty
        case .array(let value): return value.isEmpty
        case .object(let value): return value.isEmpty
        case .bool, .int, .double: return false
        }
    }

    /// Text shown in a plain text field. Objects and arrays are rendered as
    /// compact JSON so the editor can still expose them without a bespoke form.
    var editorText: String {
        switch self {
        case .null: return ""
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    static func fromEditorText(_ text: String, type: PluginConfigFieldType) -> PluginJSON {
        (try? parseEditorText(text, type: type)) ?? .null
    }

    /// Strict variant used by the config sheet. A silently replaced number or
    /// malformed JSON object would look saved while the plugin received a
    /// different value, so the editor refuses instead of guessing.
    static func parseEditorText(_ text: String, type: PluginConfigFieldType) throws -> PluginJSON {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .string, .enum, .unknown:
            return .string(text)
        case .integer:
            guard let value = Int(trimmed) else {
                throw PluginJSONError.invalidNumber(text)
            }
            return .int(value)
        case .number:
            guard let value = Double(trimmed) else {
                throw PluginJSONError.invalidNumber(text)
            }
            return .double(value)
        case .boolean:
            return .bool(trimmed == "true" || trimmed == "1")
        case .array, .object:
            guard let data = text.data(using: .utf8),
                  let value = try? JSONDecoder().decode(PluginJSON.self, from: data) else {
                throw PluginJSONError.invalidJSON(text)
            }
            switch (type, value) {
            case (.array, .array), (.object, .object):
                return value
            default:
                throw PluginJSONError.invalidJSON(text)
            }
        }
    }
}


enum PluginJSONError: LocalizedError {
    case invalidNumber(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let value):
            return String(format: L("Not a number: %@"), value)
        case .invalidJSON(let value):
            return String(format: L("Invalid JSON: %@"), String(value.prefix(80)))
        }
    }
}

// MARK: - Config fields

enum PluginConfigFieldType: String, Decodable, Hashable {
    case string
    case number
    case integer
    case boolean
    case `enum`
    case array
    case object
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PluginConfigFieldType(rawValue: raw) ?? .unknown
    }

    var title: String {
        switch self {
        case .string: return L("Text")
        case .number, .integer: return L("Number")
        case .boolean: return L("Switch")
        case .enum: return L("Choice")
        case .array: return L("List")
        case .object: return L("JSON")
        case .unknown: return L("Value")
        }
    }
}

struct PluginConfigField: Identifiable, Decodable, Hashable {
    let name: String
    let type: PluginConfigFieldType
    let defaultValue: PluginJSON?
    let enumValues: [String]
    let description: String

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case defaultValue = "default"
        case enumValues = "enum_values"
        case description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = (try? c.decode(PluginConfigFieldType.self, forKey: .type)) ?? .unknown
        defaultValue = try c.decodeIfPresent(PluginJSON.self, forKey: .defaultValue)
        enumValues = try c.decodeIfPresent([String].self, forKey: .enumValues) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

// MARK: - Installed plugins

struct PluginMenu: Identifiable, Decodable, Hashable {
    let path: String
    let menu: String
    let description: String

    var id: String { path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        menu = try c.decodeIfPresent(String.self, forKey: .menu) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case path, menu, description }
}

struct PluginMetadata: Decodable, Hashable {
    let name: String
    let version: String
    let author: String
    let githubRepository: String
    let logo: String
    let configFields: [PluginConfigField]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        githubRepository = try c.decodeIfPresent(String.self, forKey: .githubRepository) ?? ""
        logo = try c.decodeIfPresent(String.self, forKey: .logo) ?? ""
        configFields = try c.decodeIfPresent([PluginConfigField].self, forKey: .configFields) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, author
        case githubRepository = "github_repository"
        case logo
        case configFields = "config_fields"
    }
}

struct PluginInstalledEntry: Identifiable, Decodable, Hashable {
    let pluginID: String
    let path: String
    let configured: Bool
    let registered: Bool
    let enabled: Bool
    let effectiveEnabled: Bool
    let supportsOAuth: Bool
    let oauthProvider: String
    let supportsQuota: Bool
    let quotaProvider: String
    let logo: String
    let configFields: [PluginConfigField]
    let menus: [PluginMenu]
    let metadata: PluginMetadata?

    var id: String { pluginID }
    var displayName: String {
        let name = metadata?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? pluginID : name
    }
    var version: String { metadata?.version ?? "" }
    var author: String { metadata?.author ?? "" }
    var repository: String { metadata?.githubRepository ?? "" }
    var logoURL: String {
        let candidate = (metadata?.logo.isEmpty == false ? metadata?.logo : logo) ?? ""
        return candidate
    }
    var status: MTStatus {
        if effectiveEnabled { return .ok }
        if registered { return .warn }
        return .idle
    }
    var statusText: String {
        if effectiveEnabled { return L("Active") }
        if registered { return L("Disabled") }
        return L("Not loaded")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try c.decodeIfPresent(String.self, forKey: .pluginID) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        registered = try c.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        effectiveEnabled = try c.decodeIfPresent(Bool.self, forKey: .effectiveEnabled) ?? false
        supportsOAuth = try c.decodeIfPresent(Bool.self, forKey: .supportsOAuth) ?? false
        oauthProvider = try c.decodeIfPresent(String.self, forKey: .oauthProvider) ?? ""
        supportsQuota = try c.decodeIfPresent(Bool.self, forKey: .supportsQuota) ?? false
        quotaProvider = try c.decodeIfPresent(String.self, forKey: .quotaProvider) ?? ""
        logo = try c.decodeIfPresent(String.self, forKey: .logo) ?? ""
        configFields = try c.decodeIfPresent([PluginConfigField].self, forKey: .configFields) ?? []
        menus = try c.decodeIfPresent([PluginMenu].self, forKey: .menus) ?? []
        metadata = try c.decodeIfPresent(PluginMetadata.self, forKey: .metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case pluginID = "id"
        case path, configured, registered, enabled
        case effectiveEnabled = "effective_enabled"
        case supportsOAuth = "supports_oauth"
        case oauthProvider = "oauth_provider"
        case supportsQuota = "supports_quota"
        case quotaProvider = "quota_provider"
        case logo
        case configFields = "config_fields"
        case menus, metadata
    }
}

struct PluginInstalledResponse: Decodable {
    let pluginsEnabled: Bool
    let pluginsDir: String
    let plugins: [PluginInstalledEntry]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginsEnabled = try c.decodeIfPresent(Bool.self, forKey: .pluginsEnabled) ?? false
        pluginsDir = try c.decodeIfPresent(String.self, forKey: .pluginsDir) ?? ""
        plugins = try c.decodeIfPresent([PluginInstalledEntry].self, forKey: .plugins) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case pluginsEnabled = "plugins_enabled"
        case pluginsDir = "plugins_dir"
        case plugins
    }
}

// MARK: - Store plugins

struct PluginPlatform: Codable, Hashable {
    let goos: String
    let goarch: String

    var label: String {
        let os = goos == "darwin" ? "macOS" : (goos == "windows" ? "Windows" : goos)
        let arch = goarch == "amd64" ? "Intel" : (goarch == "arm64" ? "Apple silicon" : goarch)
        return "\(os) \(arch)"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goos = try c.decodeIfPresent(String.self, forKey: .goos) ?? ""
        goarch = try c.decodeIfPresent(String.self, forKey: .goarch) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(goos, forKey: .goos)
        try c.encode(goarch, forKey: .goarch)
    }

    private enum CodingKeys: String, CodingKey { case goos, goarch }
}

struct PluginStoreSource: Identifiable, Codable, Hashable {
    let sourceID: String
    let name: String
    let url: String

    var id: String { sourceID }

    var displayName: String {
        if url.localizedCaseInsensitiveContains("vanich-git/MelonTools") {
            return L("Melon Registry")
        }
        if sourceID == "official" {
            return L("Official")
        }
        return name.isEmpty ? url : name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "id"
        case name, url
    }
}

struct PluginSourceError: Codable, Hashable {
    let sourceID: String
    let sourceName: String
    let sourceURL: String
    let message: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(message, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case sourceName = "source_name"
        case sourceURL = "source_url"
        case message
    }
}

struct PluginStoreEntry: Identifiable, Codable, Hashable {
    let pluginID: String
    let storeID: String
    let sourceID: String
    let sourceName: String
    let sourceURL: String
    let name: String
    let description: String
    let author: String
    let version: String
    let repository: String
    let installType: String
    let authRequired: Bool
    let authConfigured: Bool
    let platforms: [PluginPlatform]
    let logo: String
    let homepage: String
    let license: String
    let tags: [String]
    let installed: Bool
    let installedVersion: String
    let installedSourceID: String
    let installSourceStatus: String
    let path: String
    let configured: Bool
    let registered: Bool
    let enabled: Bool
    let effectiveEnabled: Bool
    let updateAvailable: Bool

    var id: String { pluginID }
    var displayName: String { name.isEmpty ? pluginID : name }
    /// Registry source names from the engine are just the URL host, which is
    /// the same for the official registry and Melon's raw GitHub file. Name
    /// our own source explicitly so cards do not look duplicated.
    var sourceLabel: String {
        if sourceURL.localizedCaseInsensitiveContains("vanich-git/MelonTools") {
            return L("Melon Registry")
        }
        if sourceID == "official" {
            return L("Official")
        }
        return sourceName.isEmpty ? sourceURL : sourceName
    }
    var status: MTStatus {
        if updateAvailable { return .warn }
        if effectiveEnabled { return .ok }
        if installed { return .idle }
        return .idle
    }
    var statusText: String {
        if updateAvailable { return L("Update available") }
        if effectiveEnabled { return L("Installed") }
        if installed { return L("Disabled") }
        return L("Available")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try c.decodeIfPresent(String.self, forKey: .pluginID) ?? ""
        storeID = try c.decodeIfPresent(String.self, forKey: .storeID) ?? ""
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        repository = try c.decodeIfPresent(String.self, forKey: .repository) ?? ""
        installType = try c.decodeIfPresent(String.self, forKey: .installType) ?? ""
        authRequired = try c.decodeIfPresent(Bool.self, forKey: .authRequired) ?? false
        authConfigured = try c.decodeIfPresent(Bool.self, forKey: .authConfigured) ?? false
        platforms = try c.decodeIfPresent([PluginPlatform].self, forKey: .platforms) ?? []
        logo = try c.decodeIfPresent(String.self, forKey: .logo) ?? ""
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage) ?? ""
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion) ?? ""
        installedSourceID = try c.decodeIfPresent(String.self, forKey: .installedSourceID) ?? ""
        installSourceStatus = try c.decodeIfPresent(String.self, forKey: .installSourceStatus) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        registered = try c.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        effectiveEnabled = try c.decodeIfPresent(Bool.self, forKey: .effectiveEnabled) ?? false
        updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pluginID, forKey: .pluginID)
        try c.encode(storeID, forKey: .storeID)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(author, forKey: .author)
        try c.encode(version, forKey: .version)
        try c.encode(repository, forKey: .repository)
        try c.encode(installType, forKey: .installType)
        try c.encode(authRequired, forKey: .authRequired)
        try c.encode(authConfigured, forKey: .authConfigured)
        try c.encode(platforms, forKey: .platforms)
        try c.encode(logo, forKey: .logo)
        try c.encode(homepage, forKey: .homepage)
        try c.encode(license, forKey: .license)
        try c.encode(tags, forKey: .tags)
        try c.encode(installed, forKey: .installed)
        try c.encode(installedVersion, forKey: .installedVersion)
        try c.encode(installedSourceID, forKey: .installedSourceID)
        try c.encode(installSourceStatus, forKey: .installSourceStatus)
        try c.encode(path, forKey: .path)
        try c.encode(configured, forKey: .configured)
        try c.encode(registered, forKey: .registered)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(effectiveEnabled, forKey: .effectiveEnabled)
        try c.encode(updateAvailable, forKey: .updateAvailable)
    }

    private enum CodingKeys: String, CodingKey {
        case pluginID = "id"
        case storeID = "store_id"
        case sourceID = "source_id"
        case sourceName = "source_name"
        case sourceURL = "source_url"
        case name, description, author, version, repository
        case installType = "install_type"
        case authRequired = "auth_required"
        case authConfigured = "auth_configured"
        case platforms, logo, homepage, license, tags
        case installed
        case installedVersion = "installed_version"
        case installedSourceID = "installed_source_id"
        case installSourceStatus = "install_source_status"
        case path, configured, registered, enabled
        case effectiveEnabled = "effective_enabled"
        case updateAvailable = "update_available"
    }
}

struct PluginStoreResponse: Codable {
    let pluginsEnabled: Bool
    let pluginsDir: String
    let sources: [PluginStoreSource]
    let sourceErrors: [PluginSourceError]
    let plugins: [PluginStoreEntry]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginsEnabled = try c.decodeIfPresent(Bool.self, forKey: .pluginsEnabled) ?? false
        pluginsDir = try c.decodeIfPresent(String.self, forKey: .pluginsDir) ?? ""
        sources = try c.decodeIfPresent([PluginStoreSource].self, forKey: .sources) ?? []
        sourceErrors = try c.decodeIfPresent([PluginSourceError].self, forKey: .sourceErrors) ?? []
        plugins = try c.decodeIfPresent([PluginStoreEntry].self, forKey: .plugins) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pluginsEnabled, forKey: .pluginsEnabled)
        try c.encode(pluginsDir, forKey: .pluginsDir)
        try c.encode(sources, forKey: .sources)
        try c.encode(sourceErrors, forKey: .sourceErrors)
        try c.encode(plugins, forKey: .plugins)
    }

    private enum CodingKeys: String, CodingKey {
        case pluginsEnabled = "plugins_enabled"
        case pluginsDir = "plugins_dir"
        case sources
        case sourceErrors = "source_errors"
        case plugins
    }
}

struct PluginInstallResult: Decodable {
    let status: String
    let pluginID: String
    let version: String
    let path: String
    let restartRequired: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        pluginID = try c.decodeIfPresent(String.self, forKey: .pluginID) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        restartRequired = try c.decodeIfPresent(Bool.self, forKey: .restartRequired) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case pluginID = "id"
        case version, path
        case restartRequired = "restart_required"
    }
}
