import Foundation

/// Finds out whether an agent is actually on this Mac.
///
/// A config file is not proof: users delete an app and leave its settings
/// behind, and a freshly installed CLI has no config yet. The detector checks
/// the program and the app bundle separately, so the screen can tell "installed
/// but not connected" from "CLI not found".
enum AgentDetector {
    /// Folders a command-line program is installed into on macOS. Homebrew
    /// comes first: an Intel Mac uses `/usr/local`, Apple silicon `/opt/homebrew`.
    private static var binFolders: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.opencode/bin",
            "\(home)/.dsh/bin",
            "\(home)/.claude/local",
            "\(home)/.cursor/bin",
            "/usr/bin",
            "/bin"
        ]
    }

    /// App folders, the user's own included.
    private static var appFolders: [String] {
        [
            "/Applications",
            "\(NSHomeDirectory())/Applications",
            "/System/Applications"
        ]
    }

    static func binaryFound(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return binFolders.contains { folder in
            FileManager.default.isExecutableFile(atPath: "\(folder)/\(name)")
        }
    }

    static func bundleFound(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return appFolders.contains { folder in
            FileManager.default.fileExists(atPath: "\(folder)/\(name)")
        }
    }

    /// True when the program or the app the definition names is present.
    static func installed(_ definition: AgentDefinition) -> Bool {
        let detection = definition.detection
        return detection.binaries.contains(where: binaryFound)
            || detection.bundles.contains(where: bundleFound)
    }

    /// A config exists, but neither its program nor its app does.
    static func cliMissing(_ definition: AgentDefinition, hasConfig: Bool) -> Bool {
        guard hasConfig, definition.isManaged else { return false }
        guard !definition.detection.binaries.isEmpty || !definition.detection.bundles.isEmpty else {
            return false
        }
        return !installed(definition)
    }
}
