import SwiftUI
import AppKit

/// Codex CLI multi-instances: isolated CODEX_HOME per instance, bound to an account.
struct CodexInstancesView: View {
    @ObservedObject private var store = CodexStore.shared
    @ObservedObject private var instances = CodexInstanceStore.shared
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newAccountId: String? = nil
    /// Instance waiting for the delete confirmation (deleting removes its CODEX_HOME).
    @State private var pendingDelete: CodexInstance?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "codex",
                    title: L("Instances"),
                    subtitle: L("Instances subtitle")
                )

                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("New instance"), systemImage: "plus", tint: MTTheme.cyan, prominent: true) {
                        showCreate = true
                    }
                    Spacer()
                    if let message = instances.lastMessage {
                        Text(message)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                if instances.instances.isEmpty {
                    MTCard(accent: MTTheme.cyan, isBento: true) {
                        MTEmptyState(
                            systemImage: "square.on.square",
                            title: L("No instances"),
                            subtitle: L("Create an instance to run a Codex CLI session under a specific account.")
                        )
                        .frame(height: 160)
                    }
                } else {
                    ForEach(instances.instances) { instance in
                        instanceRow(instance)
                    }
                }

                Text(L("An instance keeps its own login, settings and history. Launch opens it in Terminal."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.instances")
        }
        .background(MTTheme.background)
        .onAppear {
            store.load()
            instances.load()
        }
        .sheet(isPresented: $showCreate) {
            createSheet
        }
        .confirmationDialog(
            pendingDelete.map { String(format: L("Delete instance '%@'?"), $0.name) }
                ?? L("Delete this instance?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { instance in
            Button(L("Delete"), role: .destructive) {
                instances.delete(instance)
                pendingDelete = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: { instance in
            Text(String(format: L("The instance '%@' and its Codex home (login, settings, history) will be removed."), instance.name))
        }
    }

    private func instanceRow(_ instance: CodexInstance) -> some View {
        MTCard(accent: MTTheme.cyan, isBento: true) {
            HStack(spacing: MTTheme.s3) {
                MTStatusDot(status: instance.accountId == store.currentAccountId ? .ok : .idle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.name)
                        .font(MTTheme.body(13, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(accountLabel(instance.accountId))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
                MTGlassButton(title: L("Launch"), systemImage: "play.fill", tint: MTTheme.emerald) {
                    instances.launch(instance, accounts: store.accounts)
                }
                MTGlassButton(title: L("Reveal"), systemImage: "folder", tint: MTTheme.cyan) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: instance.homePath)
                }
                Button {
                    pendingDelete = instance
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(MTTheme.ruby)
                }
                .buttonStyle(.plain)
                .help(L("Delete"))
            }
        }
    }

    private func accountLabel(_ accountId: String?) -> String {
        guard let accountId, let account = store.accounts.first(where: { $0.id == accountId }) else {
            return L("Follow current account")
        }
        return account.displayName
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            Text(L("New instance"))
                .font(MTTheme.display(20))
                .foregroundStyle(MTTheme.textPrimary)
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                Text(L("name"))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                TextField(L("e.g. work"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(MTTheme.mono(11))
                Text(L("account"))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                MTSelect(
                    selection: $newAccountId,
                    options: [(String?.none, L("Follow current account"))] +
                        store.accounts.map { (String?.some($0.id), $0.displayName) },
                    width: 240
                )
            }
            HStack {
                Spacer()
                MTGlassButton(title: L("Cancel"), tint: MTTheme.textSecondary) { showCreate = false }
                MTGlassButton(title: L("Create"), systemImage: "checkmark", tint: MTTheme.cyan, prominent: true) {
                    if instances.create(name: newName, accountId: newAccountId, accounts: store.accounts) {
                        showCreate = false
                        newName = ""
                        newAccountId = nil
                    }
                }
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 460)
        .background(MTTheme.background)
    }
}

// MARK: - Instance model + store

/// Non-isolated path namespace (usable from any context).
enum CodexInstancePaths {
    static var instancesDir: URL {
        let dir = CodexStore.supportDir.appendingPathComponent("instances", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Filesystem layout of isolated CODEX_HOME directories.
///
/// The folder is keyed by the instance UUID, never by the display name: on a
/// case-insensitive APFS volume `Work` and `work` are the same directory, so a
/// name-keyed home makes two instances share one login/auth file and deleting
/// either one wipes the other (audit CORE-04). The name is display-only now.
enum CodexInstanceHomes {
    /// `instances/<id>/codex-home`.
    static func home(root: URL, id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    /// Pre-6.0.0 layout: `instances/<display name>/codex-home`.
    static func legacyHome(root: URL, name: String, id: String) -> URL {
        root.appendingPathComponent(CodexInstance.safeDirectoryName(name, fallbackID: id), isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
    }

    /// The only directory `delete` may remove for this instance. `nil` when the
    /// computed path would escape `instances/` (a hand-edited id must never
    /// turn into an arbitrary `removeItem`).
    static func ownedContainer(root: URL, id: String) -> URL? {
        // The id comes from instances.json and may have been edited by hand.
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/") else { return nil }
        let base = root.standardizedFileURL
        let candidate = root.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard candidate.path != base.path, candidate.path.hasPrefix(base.path + "/") else {
            return nil
        }
        return candidate
    }

    /// Move (or, for a legacy collision, copy the login out of) every existing
    /// name-keyed home into its UUID home. Idempotent: a UUID home that already
    /// exists is never touched, and a shared legacy directory is never moved or
    /// deleted — the instances that used it get their own copy of `auth.json`
    /// and the old folder stays on disk for manual recovery.
    ///
    /// Returns human-readable notes for the instances it relocated.
    @discardableResult
    static func migrate(
        root: URL,
        instances: [CodexInstance],
        fileManager: FileManager = .default
    ) -> [String] {
        var notes: [String] = []
        // Two instances may map to the same legacy path. Lowercasing models
        // APFS case-insensitivity: `Work` and `work` collide there too.
        var claims: [String: [CodexInstance]] = [:]
        for instance in instances {
            let legacy = legacyHome(root: root, name: instance.name, id: instance.id)
            claims[legacy.path.lowercased(), default: []].append(instance)
        }

        for instance in instances {
            let legacy = legacyHome(root: root, name: instance.name, id: instance.id)
            guard fileManager.fileExists(atPath: legacy.path) else { continue }
            let destination = home(root: root, id: instance.id)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            let shared = (claims[legacy.path.lowercased()] ?? []).count > 1
            var createdDestination = false

            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if shared {
                    // Never rename or delete a directory another instance still
                    // points at. Copy the login so the session keeps working;
                    // history stays in the shared folder.
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    createdDestination = true
                    let source = legacy.appendingPathComponent("auth.json")
                    if fileManager.fileExists(atPath: source.path) {
                        let target = destination.appendingPathComponent("auth.json")
                        try? fileManager.removeItem(at: target)
                        try fileManager.copyItem(at: source, to: target)
                        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                    }
                    notes.append(String(
                        format: L("Instance '%@' now has its own Codex home."),
                        instance.name
                    ))
                } else {
                    try fileManager.moveItem(at: legacy, to: destination)
                    // The legacy parent (`instances/<name>`) is empty now.
                    try? fileManager.removeItem(at: legacy.deletingLastPathComponent())
                    notes.append(String(
                        format: L("Instance '%@' now has its own Codex home."),
                        instance.name
                    ))
                }
            } catch {
                // A half-created destination would make the directory look
                // migrated on the next launch and permanently keep the login
                // out of this instance. Leave no marker behind on failure.
                if createdDestination {
                    try? fileManager.removeItem(at: destination)
                }
                continue
            }
        }
        return notes
    }
}

struct CodexInstance: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var accountId: String?
    var createdAt: Date = Date()

    /// A display name is not a path component any more, but it still must be
    /// printable and must not smuggle traversal into dialogs or exports.
    static func isSafeName(_ name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return false }
        guard !clean.contains("/"), !clean.contains("\\"), !clean.contains(":") else { return false }
        return !clean.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Legacy helper kept for migrating name-keyed homes written by older
    /// builds; new homes never use it.
    static func safeDirectoryName(_ name: String, fallbackID: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "instance-\(fallbackID.prefix(8))"
        }
        return cleaned
    }

    /// Unique, case-insensitive-stable CODEX_HOME for this instance.
    var homePath: String {
        CodexInstanceHomes.home(root: CodexInstancePaths.instancesDir, id: id).path
    }
}

@MainActor
final class CodexInstanceStore: ObservableObject {
    static let shared = CodexInstanceStore()

    @Published private(set) var instances: [CodexInstance] = []
    @Published var lastMessage: String?

    static var instancesDir: URL { CodexInstancePaths.instancesDir }

    private var filePath: String { CodexStore.supportDir.appendingPathComponent("instances.json").path }

    func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let list = try? JSONDecoder().decode([CodexInstance].self, from: data) {
            instances = list
        }
        // Older builds keyed the CODEX_HOME by display name. Relocate every
        // surviving home to the UUID path once; a shared (case-colliding)
        // legacy directory is copied out, never moved or deleted.
        let notes = CodexInstanceHomes.migrate(root: Self.instancesDir, instances: instances)
        if let note = notes.last { lastMessage = note }
    }

    private func save() {
        if let data = try? JSONEncoder.pretty.encode(instances) {
            try? data.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
        }
    }

    @discardableResult
    func create(name: String, accountId: String?, accounts: [CodexAccount]) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            lastMessage = L("Name is required")
            return false
        }
        guard CodexInstance.isSafeName(clean) else {
            lastMessage = L("Name contains invalid characters")
            return false
        }
        // Names are display-only now, but a case-insensitive duplicate is still
        // confusing and was the original way two instances ended up sharing one
        // home. Reject it outright.
        guard !instances.contains(where: {
            $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            lastMessage = String(format: L("Instance '%@' already exists"), clean)
            return false
        }
        let instance = CodexInstance(name: clean, accountId: accountId)
        do {
            try FileManager.default.createDirectory(atPath: instance.homePath, withIntermediateDirectories: true)
            try writeAuth(for: instance, accounts: accounts)
        } catch {
            lastMessage = L("Create failed") + ": \(error.localizedDescription)"
            return false
        }
        instances.append(instance)
        save()
        lastMessage = String(format: L("Created '%@'"), clean)
        return true
    }

    /// Remove the instance and only its own UUID-scoped home. A legacy
    /// name-keyed directory (possibly shared with another instance) is never
    /// touched: deleting it could wipe a different instance's login (CORE-04).
    func delete(_ instance: CodexInstance) {
        instances.removeAll { $0.id == instance.id }
        save()
        let root = Self.instancesDir
        // Only `<root>/<uuid>` is this instance's; the legacy name-keyed
        // folder may belong to another instance and is never removed.
        if let owned = CodexInstanceHomes.ownedContainer(root: root, id: instance.id),
           FileManager.default.fileExists(atPath: owned.path) {
            try? FileManager.default.removeItem(at: owned)
        }
        let legacy = CodexInstanceHomes.legacyHome(root: root, name: instance.name, id: instance.id)
        if FileManager.default.fileExists(atPath: legacy.path) {
            lastMessage = String(
                format: L("Removed '%@'; the shared legacy Codex folder was kept on disk."),
                instance.name
            )
            return
        }
        lastMessage = String(format: L("Removed '%@'"), instance.name)
    }

    /// Write the bound (or current) account's tokens into the instance auth.json.
    private func writeAuth(for instance: CodexInstance, accounts: [CodexAccount]) throws {
        let account: CodexAccount? = {
            if let bound = instance.accountId { return accounts.first { $0.id == bound } }
            let path = (NSString(string: "~/.codex").expandingTildeInPath as NSString).appendingPathComponent("auth.json")
            guard let auth = try? CodexAuthFile.load(from: path), let tokens = auth.tokens else { return nil }
            return CodexAccount(tokens: tokens)
        }()
        guard let account else { return }
        let auth = CodexAuthFile.make(from: account)
        let data = try auth.encoded()
        let authURL = URL(fileURLWithPath: (instance.homePath as NSString).appendingPathComponent("auth.json"))
        // The CODEX_HOME directory holds a live token file. Create it 0700 and
        // let SecureFile write 0600 atomically; chmod-after-write leaves a
        // window where another local user could read the token.
        let directory = authURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try SecureFile.write(data, to: authURL)
    }

    /// Launch `codex` in Terminal with CODEX_HOME pointed at the instance dir.
    func launch(_ instance: CodexInstance, accounts: [CodexAccount]) {
        do {
            try writeAuth(for: instance, accounts: accounts)
        } catch {
            lastMessage = L("auth sync failed") + ": \(error.localizedDescription)"
        }
        let codexBin = ShellService.which("codex") ?? "codex"
        let script = "export CODEX_HOME=\(TerminalLauncher.shellQuote(instance.homePath))\ncd ~\n\(TerminalLauncher.shellQuote(codexBin))"
        if let error = TerminalLauncher.run(script) {
            lastMessage = L("Launch failed") + ": \(error)"
        } else {
            lastMessage = String(format: L("Launched '%@'"), instance.name)
        }
    }
}
