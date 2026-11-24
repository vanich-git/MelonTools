import CryptoKit
import Foundation
import os

/// A user-defined agent: name, config file, format and the keys to write.
///
/// This is how "add your own agent" works without shipping an adapter for
/// every client in existence: JSON (dotted paths) and dotenv files cover most
/// of them.
struct CustomAgent: Codable, Identifiable, Hashable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case json
        case env

        var id: String { rawValue }

        var title: String {
            switch self {
            case .json: return L("JSON file")
            case .env: return L("Env file")
            }
        }
    }

    var id = UUID()
    var title: String
    var configPath: String
    var format: Format = .json
    /// Dotted path for JSON (`env.OPENAI_BASE_URL`), plain key for env.
    var baseURLKey: String
    var apiKeyKey: String
    var modelKey: String = ""
    var note: String = ""
}

/// Where one agent currently points, and which backup holds its original file.
///
/// `backups` and `createdFiles` cover agents with more than one config file
/// (VS Code writes settings.json and chatLanguageModels.json). The older
/// single-file keys stay so a state file written by 6.5.0 still reverts.
struct AgentApplication: Codable, Hashable {
    var agentID: String
    var appliedAt: Date
    var configPath: String
    var backupPath: String?
    /// The file did not exist before apply, so revert removes it again.
    var createdFile: Bool
    var model: String
    var effort: String?
    /// SHA-256 of the files written, to notice a config edited by hand.
    var contentHash: String?
    /// Absolute path to the backup taken for it.
    var backups: [String: String]?
    /// Files this app created, removed again on revert.
    var createdFiles: [String]?
}

enum AgentStatus: Equatable {
    case connected
    case ready
    case cliMissing
    case notDetected
    case manual

    var label: String {
        switch self {
        case .connected: return L("Connected")
        case .ready: return L("Ready to connect")
        case .cliMissing: return L("CLI not found")
        case .notDetected: return L("Not detected")
        case .manual: return L("Manual setup")
        }
    }
}

private struct AgentStateFile: Codable {
    var applications: [String: AgentApplication] = [:]
    var customAgents: [CustomAgent] = []
}

/// Applies and reverts agent configs, keeping a backup of every file it
/// touches. Secrets are written to the agent config (that is the point), never
/// to logs.
@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()

    private static let logger = Logger(subsystem: "dev.melontools.app", category: "Agents")

    @Published private(set) var applications: [String: AgentApplication] = [:]
    @Published private(set) var customAgents: [CustomAgent] = []
    @Published private(set) var error: String?
    @Published private(set) var lastResult: String?

    private let stateURL: URL
    private let backupDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MelonTools", isDirectory: true)
        stateURL = base.appendingPathComponent("agents.json")
        backupDirectory = base.appendingPathComponent("agent-backups", isDirectory: true)
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            let data = try Data(contentsOf: stateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(AgentStateFile.self, from: data)
            applications = state.applications
            customAgents = state.customAgents
        } catch {
            self.error = String(format: L("The agent list could not be read: %@"), error.localizedDescription)
            Self.logger.error("agents load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let directory = stateURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let state = AgentStateFile(applications: applications, customAgents: customAgents)
            try encoder.encode(state).write(to: stateURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        } catch {
            self.error = String(format: L("The agent list could not be saved: %@"), error.localizedDescription)
            Self.logger.error("agents save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Catalog bridge

    /// Files the adapter may write, most specific first. `$OPENCODE_CONFIG_DIR`
    /// moves OpenCode's config, and its file is `.jsonc` in current builds.
    func configURLs(for definition: AgentDefinition) -> [URL] {
        if case .openCode = definition.integration,
           let directory = ProcessInfo.processInfo.environment["OPENCODE_CONFIG_DIR"],
           !directory.isEmpty {
            let base = URL(
                fileURLWithPath: (directory as NSString).expandingTildeInPath,
                isDirectory: true
            )
            return [
                base.appendingPathComponent("opencode.jsonc"),
                base.appendingPathComponent("opencode.json")
            ]
        }
        return definition.configURLs
    }

    func status(for definition: AgentDefinition) -> AgentStatus {
        if applications[definition.id] != nil {
            // Connected once, but the program is gone: the config is stale and
            // the client cannot read it, so "Connected" would be a lie.
            if definition.isManaged,
               AgentDetector.cliMissing(definition, hasConfig: true) {
                return .cliMissing
            }
            return .connected
        }
        if customAgent(for: definition) != nil {
            guard let url = definition.configURL else { return .manual }
            return FileManager.default.fileExists(atPath: url.path) ? .ready : .notDetected
        }
        guard definition.isManaged else { return .manual }
        let urls = configURLs(for: definition)
        let hasConfig = urls.contains { FileManager.default.fileExists(atPath: $0.path) }
        if hasConfig {
            // The settings are there but the program is gone: say so instead
            // of offering a connect the client will never read.
            return AgentDetector.cliMissing(definition, hasConfig: true) ? .cliMissing : .ready
        }
        return AgentDetector.installed(definition) ? .ready : .notDetected
    }

    func application(for definition: AgentDefinition) -> AgentApplication? {
        applications[definition.id]
    }

    /// True when a connected agent's file changed after Melon Tools wrote it.
    func drift(for definition: AgentDefinition) -> Bool {
        guard let application = applications[definition.id],
              let hash = application.contentHash
        else { return false }
        let paths = application.backups?.keys.sorted() ?? [application.configPath]
        var edits: [AgentFileEdit] = []
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return true
            }
            edits.append(AgentFileEdit(path: path, text: text))
        }
        return Self.contentHash(edits) != hash
    }

    /// The custom agents shown next to the built-in ones. They share the
    /// `custom:<uuid>` id space so both lists can live in one array.
    var customDefinitions: [AgentDefinition] {
        customAgents.map { custom in
            AgentDefinition(
                id: "custom:\(custom.id.uuidString)",
                title: custom.title,
                subtitle: custom.note.isEmpty ? custom.configPath : custom.note,
                systemImage: custom.format == .json ? "curlybraces" : "doc.text",
                group: .desktop,
                configPaths: [custom.configPath],
                integration: .manual(custom.baseURLKey),
                note: custom.note
            )
        }
    }

    func customAgent(for definition: AgentDefinition) -> CustomAgent? {
        guard definition.id.hasPrefix("custom:"),
              let uuid = UUID(uuidString: String(definition.id.dropFirst("custom:".count)))
        else { return nil }
        return customAgents.first { $0.id == uuid }
    }

    // MARK: - Apply / revert

    /// Writes the gateway values into the agent config and keeps a backup.
    @discardableResult
    func apply(_ definition: AgentDefinition, context: AgentApplyContext) throws -> String {
        let urls = configURLs(for: definition)
        guard !urls.isEmpty else {
            throw AgentConfigError.unsupported(L("This agent has no config file Melon Tools can edit safely."))
        }

        var files: [String: String] = [:]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            files[url.path] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        let edits: [AgentFileEdit]
        if let custom = customAgent(for: definition) {
            let url = urls[0]
            let updated = try applyCustom(custom, current: files[url.path] ?? "", context: context)
            edits = [AgentFileEdit(path: url.path, text: updated)]
        } else {
            edits = try AgentAdapters.edits(
                definition: definition,
                urls: urls,
                files: files,
                context: context
            )
        }
        guard let first = edits.first else {
            throw AgentConfigError.unsupported(L("This agent has no config file Melon Tools can edit safely."))
        }

        var backups: [String: String] = [:]
        var createdFiles: [String] = []
        for edit in edits {
            let url = URL(fileURLWithPath: edit.path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists {
                backups[url.path] = try makeBackup(of: url, agentID: definition.id)
            } else {
                createdFiles.append(url.path)
            }
            try write(edit.text, to: url, preservingAttributesOf: exists ? url : nil)
        }

        let application = AgentApplication(
            agentID: definition.id,
            appliedAt: Date(),
            configPath: first.path,
            backupPath: backups[first.path],
            createdFile: createdFiles.contains(first.path),
            model: context.model,
            effort: context.effort,
            contentHash: Self.contentHash(edits),
            backups: backups,
            createdFiles: createdFiles
        )
        applications[definition.id] = application
        save()
        error = nil
        lastResult = String(format: L("Connected %@."), definition.title)
        return first.path
    }

    /// Restores the backup taken before the last apply. Files this app created
    /// are removed again.
    func revert(_ definition: AgentDefinition) throws {
        guard let application = applications[definition.id] else { return }
        let created = Set(application.createdFiles ?? [])
        let backupPaths = application.backups.map { Array($0.keys) } ?? []
        var paths = Set(backupPaths)
        paths.formUnion(created)
        if paths.isEmpty {
            // A state file from 6.5.0, before multi-file applies.
            paths = [application.configPath]
        }

        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path)
            if let backup = application.backups?[path],
               FileManager.default.fileExists(atPath: backup) {
                let original = try String(contentsOfFile: backup, encoding: .utf8)
                let exists = FileManager.default.fileExists(atPath: url.path)
                try write(original, to: url, preservingAttributesOf: exists ? url : nil)
            } else if created.contains(path) || (application.createdFile && path == application.configPath) {
                try? FileManager.default.removeItem(at: url)
            } else if path == application.configPath,
                      let backup = application.backupPath,
                      FileManager.default.fileExists(atPath: backup) {
                let original = try String(contentsOfFile: backup, encoding: .utf8)
                let exists = FileManager.default.fileExists(atPath: url.path)
                try write(original, to: url, preservingAttributesOf: exists ? url : nil)
            }
        }

        applications.removeValue(forKey: definition.id)
        save()
        error = nil
        lastResult = String(format: L("Restored the previous %@ config."), definition.title)
    }

    // MARK: - Custom agents

    func addCustom(_ agent: CustomAgent) -> String? {
        if let problem = Self.validate(custom: agent, existing: customAgents) { return problem }
        customAgents.append(agent)
        save()
        return nil
    }

    func updateCustom(_ agent: CustomAgent) -> String? {
        let others = customAgents.filter { $0.id != agent.id }
        if let problem = Self.validate(custom: agent, existing: others) { return problem }
        guard let index = customAgents.firstIndex(where: { $0.id == agent.id }) else { return nil }
        customAgents[index] = agent
        save()
        return nil
    }

    func removeCustom(id: UUID) {
        if let application = applications["custom:\(id.uuidString)"] {
            let created = Set(application.createdFiles ?? [])
            let backupPaths = application.backups.map { Array($0.keys) } ?? []
            let paths = Set(backupPaths).union(created)
            for path in paths {
                let url = URL(fileURLWithPath: path)
                if let backup = application.backups?[path],
                   FileManager.default.fileExists(atPath: backup),
                   let original = try? String(contentsOfFile: backup, encoding: .utf8) {
                    try? write(original, to: url, preservingAttributesOf: nil)
                } else if created.contains(path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            applications.removeValue(forKey: "custom:\(id.uuidString)")
        }
        customAgents.removeAll { $0.id == id }
        save()
    }

    static func validate(custom: CustomAgent, existing: [CustomAgent]) -> String? {
        let title = custom.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return L("Enter a name for the agent.") }
        if existing.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            return L("An agent with this name already exists.")
        }
        let path = custom.configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return L("Enter the path to the agent config.") }
        if !path.hasPrefix("/") && !path.hasPrefix("~") {
            return L("The path must be absolute or start with ~.")
        }
        if custom.baseURLKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("Enter the key that holds the base URL.")
        }
        if custom.apiKeyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("Enter the key that holds the API key.")
        }
        return nil
    }

    private func applyCustom(
        _ custom: CustomAgent,
        current: String,
        context: AgentApplyContext
    ) throws -> String {
        switch custom.format {
        case .json:
            return try AgentAdapters.updatingJSON(current, path: custom.configPath) { root in
                Self.setJSONPath(root: &root, path: custom.baseURLKey, value: context.baseURL)
                Self.setJSONPath(root: &root, path: custom.apiKeyKey, value: context.apiKey)
                if !custom.modelKey.trimmingCharacters(in: .whitespaces).isEmpty,
                   !context.model.isEmpty {
                    Self.setJSONPath(root: &root, path: custom.modelKey, value: context.model)
                }
            }
        case .env:
            var text = current
            text = AgentAdapters.upsertEnvValue(in: text, key: custom.baseURLKey, value: context.baseURL)
            text = AgentAdapters.upsertEnvValue(in: text, key: custom.apiKeyKey, value: context.apiKey)
            if !custom.modelKey.trimmingCharacters(in: .whitespaces).isEmpty, !context.model.isEmpty {
                text = AgentAdapters.upsertEnvValue(in: text, key: custom.modelKey, value: context.model)
            }
            return text
        }
    }

    /// `a.b.c` creates nested objects. An empty path is ignored.
    static func setJSONPath(root: inout [String: Any], path: String, value: String) {
        let parts = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard let first = parts.first else { return }
        if parts.count == 1 {
            root[first] = value
        } else {
            let child = root[first] as? [String: Any] ?? [:]
            root[first] = setting(child, keys: Array(parts.dropFirst()), value: value)
        }
    }

    private static func setting(_ dictionary: [String: Any], keys: [String], value: String) -> [String: Any] {
        guard let key = keys.first else { return dictionary }
        var copy = dictionary
        if keys.count == 1 {
            copy[key] = value
        } else {
            let child = copy[key] as? [String: Any] ?? [:]
            copy[key] = setting(child, keys: Array(keys.dropFirst()), value: value)
        }
        return copy
    }

    // MARK: - Hashing

    /// Stable hash of the files written: path and text, in path order, so a
    /// later read of the same files compares equal whatever the adapter order.
    static func contentHash(_ edits: [AgentFileEdit]) -> String {
        let joined = edits
            .sorted { $0.path < $1.path }
            .map { $0.path + "\u{0}" + $0.text }
            .joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Files

    private func makeBackup(of url: URL, agentID: String) throws -> String {
        if !FileManager.default.fileExists(atPath: backupDirectory.path) {
            try FileManager.default.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeID = agentID.replacingOccurrences(of: ":", with: "-")
        let name = "\(safeID)-\(stamp)-\(url.lastPathComponent)"
        let destination = backupDirectory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination.path
    }

    private func write(_ text: String, to url: URL, preservingAttributesOf original: URL?) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let permissions = original
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber }
            ?? NSNumber(value: 0o600)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Backup files for one agent, newest first. Shown on the agent page.
    func backups(for definition: AgentDefinition) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        let prefix = definition.id.replacingOccurrences(of: ":", with: "-") + "-"
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
