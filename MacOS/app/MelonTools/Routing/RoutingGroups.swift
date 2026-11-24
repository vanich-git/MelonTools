import Foundation
import os

/// One provider model inside a routing group.
struct RoutingGroupMember: Codable, Identifiable, Hashable {
    var id = UUID()
    var sourceID: String
    var modelID: String
}

/// A routing group: one model name that several upstreams can serve.
///
/// The engine has no cross-provider group primitive. The trick this store
/// uses is the one the engine does support: the same alias is declared on every
/// member's provider entry, so `/v1/models` lists the alias once and a request
/// fails over between providers. Ordering across providers is decided by the
/// engine (provider model count, then name), never by the order of the rows
/// here; ordering inside one provider is preserved.
struct RoutingGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Model name clients ask for. Lowercase, no spaces.
    var alias: String
    var note: String = ""
    var enabled: Bool = true
    var members: [RoutingGroupMember] = []
    var createdAt = Date()
}

/// Persisted store for routing groups: `routing-groups.json` (0600) next to
/// the other app state. YAML generation is a pure function of this list.
@MainActor
final class RoutingGroupsStore: ObservableObject {
    static let shared = RoutingGroupsStore()

    private static let logger = Logger(subsystem: "dev.melontools.app", category: "Routing")

    @Published private(set) var groups: [RoutingGroup] = []
    @Published private(set) var error: String?
    @Published private(set) var isLoaded = false

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base
            .appendingPathComponent("MelonTools", isDirectory: true)
            .appendingPathComponent("routing-groups.json")
        load()
    }

    // MARK: - Load / save

    func loadIfNeeded() {
        if !isLoaded { load() }
    }

    private func load() {
        defer { isLoaded = true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            groups = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            groups = try decoder.decode([RoutingGroup].self, from: data)
            error = nil
        } catch {
            self.error = String(format: L("The routing groups could not be read: %@"), error.localizedDescription)
            Self.logger.error("routing groups load failed: \(error.localizedDescription, privacy: .public)")
            groups = []
        }
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
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
            try encoder.encode(groups).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            error = nil
        } catch {
            self.error = String(format: L("The routing groups could not be saved: %@"), error.localizedDescription)
            Self.logger.error("routing groups save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Mutation

    /// Validates and appends a group. Returns an error message or nil.
    @discardableResult
    func add(alias rawAlias: String, note: String = "", members: [RoutingGroupMember]) -> String? {
        let alias = Self.normalize(alias: rawAlias)
        if let problem = Self.aliasProblem(alias, existing: Set(groups.map(\.alias))) {
            return problem
        }
        guard !members.isEmpty else { return L("Add at least one model to the group.") }
        let unique = Self.uniqueMembers(members)
        groups.append(RoutingGroup(alias: alias, note: note, members: unique))
        save()
        return nil
    }

    @discardableResult
    func update(_ group: RoutingGroup) -> String? {
        let alias = Self.normalize(alias: group.alias)
        let others = Set(groups.filter { $0.id != group.id }.map(\.alias))
        if let problem = Self.aliasProblem(alias, existing: others) {
            return problem
        }
        guard !group.members.isEmpty else { return L("Add at least one model to the group.") }
        let unique = Self.uniqueMembers(group.members)
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return nil }
        var updated = group
        updated.alias = alias
        updated.members = unique
        groups[index] = updated
        save()
        return nil
    }

    func remove(id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    func setEnabled(id: UUID, enabled: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].enabled = enabled
        save()
    }

    func moveMember(groupID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].members.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    // MARK: - YAML contribution

    /// Alias models per source id. Only sources that write an
    /// `openai-compatibility`/`claude` block can carry them, so OAuth-only
    /// Antigravity and the Codex pool are skipped here.
    func aliasModels(sources: [ModelSource]) -> [String: [SourceModel]] {
        Self.aliasModels(groups: groups, sources: sources)
    }

    /// Pure variant: group list in, alias models out. Tested without touching
    /// the user's stored groups.
    nonisolated static func aliasModels(
        groups: [RoutingGroup],
        sources: [ModelSource]
    ) -> [String: [SourceModel]] {
        var out: [String: [SourceModel]] = [:]
        for group in groups where group.enabled && !group.members.isEmpty {
            for member in group.members {
                guard let source = sources.first(where: { $0.id == member.sourceID && $0.enabled }),
                      let model = source.models.first(where: { $0.id == member.modelID })
                else { continue }
                guard model.anthropicOnly != true || source.kind == .claude else { continue }
                var aliasModel = model
                aliasModel.alias = group.alias
                aliasModel.display = group.alias
                aliasModel.enabled = true
                out[source.id, default: []].append(aliasModel)
            }
        }
        return out
    }

    /// How many groups mention one source, for the provider page.
    func groupCount(for sourceID: String) -> Int {
        groups.filter { group in
            group.enabled && group.members.contains { $0.sourceID == sourceID }
        }.count
    }

    // MARK: - Validation

    static func normalize(alias: String) -> String {
        alias
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Aliases are client-facing model ids: keep them to the same alphabet the
    /// provider loaders use, so a paste into any client works.
    static func aliasProblem(_ alias: String, existing: Set<String>) -> String? {
        guard !alias.isEmpty else { return L("Enter a model name for the group.") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._/:")
        if alias.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return L("Use lowercase letters, digits, dots, dashes, slashes or underscores.")
        }
        if alias.count > 64 { return L("The name is longer than 64 characters.") }
        if existing.contains(alias) {
            return L("A group with this name already exists.")
        }
        return nil
    }

    /// Drops the rows that would take the same share twice.
    ///
    /// Two rows for one provider and the very same model id are one route, and
    /// the engine weights the route, not the row: leaving both in doubles that
    /// provider's share of the traffic without giving it anything to serve it
    /// with. The comparison is the raw id on purpose. Two spellings of one
    /// model id are two different ids as far as the upstream is concerned, and
    /// folding them together would silently drop a member the user added.
    nonisolated static func uniqueMembers(_ members: [RoutingGroupMember]) -> [RoutingGroupMember] {
        var seen: Set<String> = []
        return members.filter { member in
            seen.insert(member.sourceID + "|" + member.modelID).inserted
        }
    }
}