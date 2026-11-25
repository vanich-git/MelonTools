import Foundation

/// Small, dependency-free settings bridge for the native plugin host.
///
/// The gateway writes its config long before any plugin UI is constructed, so
/// this type must not reference `PluginStore` or any other observable object.
/// Keeping the path and the opt-in here also gives tests a deterministic way to
/// describe the host without spinning up the app.
enum PluginSettings {
    /// The plugin host is opt-in: a fresh install writes `enabled: false`, and
    /// the first explicit install flips it on. Existing sessions keep the
    /// user's choice.
    static let enabledKey = "pluginHostEnabled"
    static let registryURLKey = "pluginRegistryURL"

    /// Melon's own registry. It is intentionally a plain raw GitHub URL: the
    /// engine accepts a list of registry URLs, so a self-hosted mirror can be
    /// added later without an app update.
    static let defaultRegistryURL = "https://raw.githubusercontent.com/vanich-git/MelonTools/main/registry/registry.json"

    static var registryURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: registryURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty == false ? stored! : defaultRegistryURL)
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: registryURLKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: registryURLKey)
            }
        }
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// `false` on a profile where the switch was never touched. A stored
    /// `false` and an absent key both read as "disabled", but only the absent
    /// key means "no local decision yet", so the store may seed it.
    static var hasHostPreference: Bool {
        UserDefaults.standard.object(forKey: enabledKey) != nil
    }

    /// Absolute path handed to the engine. `CodexGatewayService.spawn` starts
    /// the sidecar without a working directory, so a relative `plugins` path
    /// would resolve against `/` and discovery would come up empty.
    @MainActor
    static var pluginsDir: URL {
        let dir = CodexGatewayService.gatewayDir.appendingPathComponent("plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// YAML block appended to the generated gateway config. It is emitted on
    /// every write, even while disabled, so the store can be inspected without
    /// enabling native code execution.
    @MainActor
    static func gatewayYAML(enabled: Bool = isEnabled) -> String {
        let dir = yamlScalar(pluginsDir.path)
        let source = yamlScalar(registryURL)
        return """

        # Native plugins. The host loads signed-by-trust dynamic libraries in
        # process, so the store is opt-in and installs require explicit consent.
        plugins:
          enabled: \(enabled ? "true" : "false")
          dir: "\(dir)"
          store-sources:
            - "\(source)"

        """
    }

    /// Double-quoted YAML scalars treat `\` as an escape character, so a path
    /// or URL containing a backslash, quote or control byte would otherwise
    /// produce a config the engine cannot parse. Mirrors the Windows
    /// `gateway::yaml_escape`.
    static func yamlScalar(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                // Rust drops every control scalar (C0, DEL and C1), so match
                // that here or the two platforms emit different YAML.
                if CharacterSet.controlCharacters.contains(scalar) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
