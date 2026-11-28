import Foundation
import os

/// One provider model inside a routing group.
struct RoutingGroupMember: Codable, Identifiable, Hashable {
    var id = UUID()
    var sourceID: String
    var modelID: String

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, modelID
        case sourceId, modelId
    }

    init(id: UUID = UUID(), sourceID: String, modelID: String) {
        self.id = id
        self.sourceID = sourceID
        self.modelID = modelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
            ?? container.decode(String.self, forKey: .sourceId)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
            ?? container.decode(String.self, forKey: .modelId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(modelID, forKey: .modelID)
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, alias, note, enabled, members, createdAt
    }

    init(
        id: UUID = UUID(),
        alias: String,
        note: String = "",
        enabled: Bool = true,
        members: [RoutingGroupMember] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.alias = alias
        self.note = note
        self.enabled = enabled
        self.members = members
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        alias = try container.decode(String.self, forKey: .alias)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        members = try container.decodeIfPresent([RoutingGroupMember].self, forKey: .members) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(alias, forKey: .alias)
        try container.encode(note, forKey: .note)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(members, forKey: .members)
        try container.encode(createdAt, forKey: .createdAt)
    }
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
    /// A load failure is never overwritten by a later save: the stored file
    /// may still hold the user's groups and must stay intact until they act.
    private(set) var hasLoadFailure = false
    /// Config generation must not run while the persisted groups are unknown.
    /// Config generation must not run while groups are unknown, including the
    /// window before the first load.
    var isSafeToWrite: Bool { isLoaded && !hasLoadFailure }

    private let fileURL: URL

    /// Injectable for tests only. Production always uses the shared store.
    static func testStore(fileURL: URL) -> RoutingGroupsStore {
        RoutingGroupsStore(fileURL: fileURL)
    }

    private init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? base
            .appendingPathComponent("MelonTools", isDirectory: true)
            .appendingPathComponent("routing-groups.json")
        load()
    }

    // MARK: - Load / save

    /// Retries a failed load on the next call. The user can repair or delete the
    /// file without relaunching the app; until that read succeeds, writes stay
    /// blocked (`isSafeToWrite`).
    func loadIfNeeded() {
        if !isLoaded || hasLoadFailure { load() }
    }

    private func load() {
        defer { isLoaded = true }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Only a missing file means "fresh install". A permission problem
            // on the file or its parent leaves the stored groups unknown:
            // `fileExists` would report false there too, which used to let an
            // empty list overwrite groups the app simply could not read.
            if Self.isMissingFile(error) {
                groups = []
                self.error = nil
                hasLoadFailure = false
            } else {
                failLoad(error)
            }
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            groups = try decoder.decode([RoutingGroup].self, from: data)
            error = nil
            hasLoadFailure = false
        } catch {
            failLoad(error)
        }
    }

    private func failLoad(_ error: Error) {
        hasLoadFailure = true
        self.error = String(format: L("The routing groups could not be read: %@"), error.localizedDescription)
        Self.logger.error("routing groups load failed: \(error.localizedDescription, privacy: .public)")
        groups = []
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == ENOENT
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT
    }

    /// Returns nil on success or a visible error message. The in-memory list is
    /// restored when a write fails, so the UI never shows groups that were not
    /// persisted. A failed load blocks all writes until the file is recovered.
    @discardableResult
    private func save(rollingBackFrom previous: [RoutingGroup]) -> String? {
        if hasLoadFailure {
            groups = previous
            let message = L("Fix or remove the unreadable routing groups file before saving.")
            error = message
            return message
        }
        // SecureFile writes the sibling temp file with 0600 from creation and
        // renames it atomically, so no failing step remains after the rename.
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SecureFile.write(try encoder.encode(groups), to: fileURL)
            error = nil
            return nil
        } catch {
            groups = previous
            let message = String(format: L("The routing groups could not be saved: %@"), error.localizedDescription)
            self.error = message
            Self.logger.error("routing groups save failed: \(error.localizedDescription, privacy: .public)")
            return message
        }
    }

    private func persist(_ mutate: () -> Void) -> String? {
        let previous = groups
        mutate()
        return save(rollingBackFrom: previous)
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
        return persist {
            groups.append(RoutingGroup(alias: alias, note: note, members: unique))
        }
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
        guard groups.contains(where: { $0.id == group.id }) else { return nil }
        return persist {
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            var updated = group
            updated.alias = alias
            updated.members = unique
            groups[index] = updated
        }
    }

    @discardableResult
    func remove(id: UUID) -> String? {
        guard groups.contains(where: { $0.id == id }) else { return nil }
        return persist {
            groups.removeAll { $0.id == id }
        }
    }

    @discardableResult
    func setEnabled(id: UUID, enabled: Bool) -> String? {
        guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].enabled != enabled else { return nil }
        return persist {
            groups[index].enabled = enabled
        }
    }

    @discardableResult
    func moveMember(groupID: UUID, from offsets: IndexSet, to destination: Int) -> String? {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        return persist {
            groups[index].members.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    // MARK: - Member diagnostics

    /// How one member resolves against the current sources. A disabled model is
    /// not a problem: the group alias turns it on for this route, which is the
    /// whole point of a group. A missing or disabled source is.
    enum MemberStatus: Equatable {
        /// Source exists and is on, model exists: the member can serve.
        case active
        /// The model is off individually; the group still serves it.
        case enabledByGroup
        case sourceMissing
        case sourceDisabled
        case modelMissing
        /// The source never reaches `api-keys` (OAuth-only Antigravity, a
        /// plugin row), so its alias would be silently lost.
        case notPublishable
    }

    nonisolated static func memberStatus(
        _ member: RoutingGroupMember,
        sources: [ModelSource]
    ) -> MemberStatus {
        guard let source = sources.first(where: { $0.id == member.sourceID }) else {
            return .sourceMissing
        }
        guard source.enabled else { return .sourceDisabled }
        guard let model = source.models.first(where: { $0.id == member.modelID }) else {
            return .modelMissing
        }
        guard canCarryAlias(source) else { return .notPublishable }
        return model.enabled ? .active : .enabledByGroup
    }

    /// True when `gatewayYAML` writes a provider block that can carry a model
    /// alias for this source. Antigravity is OAuth-only and plugin rows are
    /// synthetic: neither is emitted into `api-keys`. A provider without a key
    /// is skipped by `gatewayYAML` as well, so an alias there would be lost.
    nonisolated static func canCarryAlias(_ source: ModelSource) -> Bool {
        switch source.kind {
        case .antigravity, .plugin:
            return false
        case .localAI:
            return true
        default:
            return !source.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
                let status = Self.memberStatus(member, sources: sources)
                guard status == .active || status == .enabledByGroup,
                      let source = sources.first(where: { $0.id == member.sourceID }),
                      let model = source.models.first(where: { $0.id == member.modelID })
                else { continue }
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