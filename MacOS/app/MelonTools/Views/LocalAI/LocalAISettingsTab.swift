import SwiftUI
import AppKit

struct LocalAISettingsTab: View {
    @StateObject private var runtimeStore = RuntimeStore.shared
    @ObservedObject var store = LocalModelStore.shared
    @ObservedObject var runtime = LocalInferenceService.shared
    @ObservedObject var hw = LocalHardwareService.shared
    @ObservedObject private var gateway = CodexGatewayService.shared

    @State private var hfToken = ""
    @State private var showingTokenSaved = false
    @State private var customServerPath = ""
    @State private var runtimeURL = ""
    @State private var runtimeSHA256 = ""
    @State private var runtimeActionError: String?
    @State private var showingRuntimeCatalog = false
    @State private var runtimeDeleteError: String?
    @State private var pendingRuntimeDelete: RuntimeManifest?
    @State private var pendingStorageURL: URL?
    @State private var storageError: String?
    @State private var storageBusy = false
    @State private var tokenError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                // Models Storage Directory
                MTCard(title: L("Storage Location"), systemImage: "folder", accent: MTTheme.cyan) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Models Directory"))
                                    .font(MTTheme.body(12, weight: .semibold))
                                    .foregroundStyle(MTTheme.textPrimary)
                                Text(store.modelsDirectory.path)
                                    .font(MTTheme.body(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(L("Change...")) {
                                chooseDirectory()
                            }
                            .buttonStyle(.bordered)

                            if store.customModelsDirectory != nil {
                                Button(L("Reset")) {
                                    Task { await useInternalStorage() }
                                }
                                .buttonStyle(.plain)
                                .font(MTTheme.body(11))
                                .foregroundStyle(MTTheme.textTertiary)
                                .disabled(storageBusy)
                            }
                        }

                        if let issue = storageIssueText {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                Text(issue)
                                    .font(MTTheme.body(10.5))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(MTTheme.danger)
                        }

                        if let error = storageError {
                            Text(error)
                                .font(MTTheme.body(10.5))
                                .foregroundStyle(MTTheme.danger)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let progress = store.relocationProgress {
                            VStack(alignment: .leading, spacing: 3) {
                                ProgressView(value: progress)
                                Text(store.relocationMessage ?? L("Moving models..."))
                                    .font(MTTheme.body(10))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                        }

                        if let backup = LocalAIMigration.latestBackup {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 9))
                                Text(String(format: L("Pre-upgrade backup: %@"), backup.lastPathComponent))
                                    .font(MTTheme.body(9.5))
                                    .foregroundStyle(MTTheme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                        }

                        Divider().background(Color.primary.opacity(0.08))

                        HStack(spacing: MTTheme.s4) {
                            HStack(spacing: 6) {
                                Text(L("Free Disk Space:"))
                                    .font(MTTheme.body(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                                Text(LocalHardwareService.formatBytes(hw.hardwareInfo.modelsDiskFreeSpace))
                                    .font(MTTheme.body(11, weight: .semibold))
                                    .foregroundStyle(MTTheme.textPrimary)
                            }
                            HStack(spacing: 6) {
                                Text(L("Total Models Size:"))
                                    .font(MTTheme.body(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                                Text(LocalHardwareService.formatBytes(store.totalDiskBytes))
                                    .font(MTTheme.body(11, weight: .semibold))
                                    .foregroundStyle(MTTheme.emerald)
                            }
                        }
                    }
                }

                // llama-server Binary Path
                MTCard(title: L("Inference Engine Binary"), systemImage: "terminal", accent: MTTheme.violet) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("llama-server Path"))
                                    .font(MTTheme.body(12, weight: .semibold))
                                    .foregroundStyle(MTTheme.textPrimary)
                                if let bin = runtime.binaryURL {
                                    Text(bin.path)
                                        .font(MTTheme.body(11))
                                        .foregroundStyle(MTTheme.emerald)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    Text(L("Engine not found. Reinstall Melon Tools or pick a binary manually."))
                                        .font(MTTheme.body(11))
                                        .foregroundStyle(MTTheme.danger)
                                }
                            }
                            Spacer()
                            Button(L("Browse...")) {
                                chooseServerBinary()
                            }
                            .buttonStyle(.bordered)

                            if runtime.customBinaryPath != nil {
                                Button(L("Reset")) {
                                    runtime.customBinaryPath = nil
                                }
                                .buttonStyle(.plain)
                                .font(MTTheme.body(11))
                                .foregroundStyle(MTTheme.textTertiary)
                            }
                        }

                        // Provenance matters: the bundled, checksummed engine is
                        // the supported path, a system install is not. Both the
                        // label and the digest now come from the file that will
                        // actually run, not from an unrelated manifest.
                        HStack(spacing: MTTheme.s3) {
                            engineFact(
                                label: L("Runtime"),
                                value: runtimeProvenanceLabel,
                                tint: runtime.isUsingBundledRuntime ? MTTheme.emerald : MTTheme.amber
                            )
                            engineFact(
                                label: L("Version"),
                                value: runtime.runtimeVersion ?? L("Unknown"),
                                tint: MTTheme.textSecondary
                            )
                            engineFact(
                                label: L("Integrity"),
                                value: runtime.runtimeChecksumStatus,
                                tint: runtime.runtimeChecksumStatus == L("Verified") ? MTTheme.emerald : MTTheme.amber
                            )
                        }

                        Text(L("The bundled runtime is pinned and checksummed. A binary picked here or found in Homebrew is used as a fallback and reported as external."))
                            .font(MTTheme.body(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Engine scheduling: how many requests run at once, when an
                // idle model releases its memory, and how many models the
                // router keeps loaded (§12.1, §11.4).
                MTCard(title: L("Engine Scheduling"), systemImage: "gauge.with.dots.needle.67percent", accent: MTTheme.cyan) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        settingRow(L("Parallel requests")) {
                            MTSelect(selection: parallelRequests, options: [
                                (1, L("1 (lowest memory)")),
                                (2, "2"),
                                (3, "3"),
                                (4, "4"),
                            ], width: 190)
                        }

                        settingRow(L("Unload model after idle")) {
                            MTSelect(selection: idleUnload, options: [
                                (0, L("Never")),
                                (300, L("5 minutes")),
                                (900, L("15 minutes")),
                                (1800, L("30 minutes")),
                                (3600, L("1 hour")),
                            ], width: 190)
                        }

                        settingRow(L("Models kept in memory")) {
                            MTSelect(selection: modelsMax, options: [
                                (1, L("1 (recommended)")),
                                (2, "2"),
                                (3, "3"),
                            ], width: 190)
                        }

                        Text(L("Parallel requests share one context window, so a higher value splits the context between slots. Idle unload frees RAM when no client is using the model; the next request loads it again automatically."))
                            .font(MTTheme.body(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: MTTheme.s3) {
                            Text(L("Scheduling changes take effect after the engine restarts."))
                                .font(MTTheme.body(10))
                                .foregroundStyle(MTTheme.textTertiary)
                            Spacer()
                            Button(L("Restart Engine")) {
                                Task { await runtime.applySettingsChange() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!runtime.status.isRunning)
                        }
                    }
                }

                // Runtime manager (§13.3): several engines with different
                // backends can be installed, one is active.
                MTCard(title: L("Inference Runtimes"), systemImage: "square.stack.3d.up", accent: MTTheme.emerald) {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        if runtimeStore.runtimes.isEmpty {
                            Text(L("No runtimes installed."))
                                .font(MTTheme.body(11))
                                .foregroundStyle(MTTheme.danger)
                        }

                        ForEach(runtimeStore.runtimes) { manifest in
                            runtimeRow(manifest)
                        }

                        HStack(spacing: MTTheme.s3) {
                            Button(L("Browse Runtimes...")) { showingRuntimeCatalog = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(runtimeStore.isInstalling)
                            Button(L("Add Runtime...")) { addRuntime() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(runtimeStore.isInstalling)
                            Spacer()
                        }
                        .padding(.top, 2)

                        Divider()
                        TextField(L("Runtime archive URL (.tar.gz)"), text: $runtimeURL)
                            .textFieldStyle(.roundedBorder)
                        TextField(L("Archive SHA-256 (required)"), text: $runtimeSHA256)
                            .textFieldStyle(.roundedBorder)
                            .font(MTTheme.mono(10))
                        HStack {
                            Button(L("Download Runtime")) {
                                guard let url = URL(string: runtimeURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                                    runtimeActionError = L("Invalid runtime URL.")
                                    return
                                }
                                runtimeActionError = nil
                                runtimeStore.install(from: url, sha256: runtimeSHA256.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            .disabled(runtimeStore.isInstalling || runtimeURL.isEmpty || !RuntimePackageInstaller.validDigest(runtimeSHA256.trimmingCharacters(in: .whitespacesAndNewlines)))
                            if runtimeStore.isInstalling {
                                Button(L("Cancel")) { runtimeStore.cancelInstall() }
                            }
                        }
                        if runtimeStore.isInstalling {
                            if runtimeStore.installTotal > 0 {
                                ProgressView(value: Double(runtimeStore.installBytes), total: Double(runtimeStore.installTotal))
                            } else { ProgressView().controlSize(.small) }
                            Text(ByteCountFormatter.string(fromByteCount: runtimeStore.installBytes, countStyle: .file))
                                .font(MTTheme.mono(10))
                        }
                        if !runtimeStore.installStage.isEmpty {
                            Text(runtimeStore.installStage).font(MTTheme.body(11))
                        }
                        if let error = runtimeActionError ?? runtimeStore.installError {
                            Text(error).font(MTTheme.body(11)).foregroundStyle(MTTheme.danger)
                                .textSelection(.enabled)
                        }
                        Text(L("Only install code you trust. Obtain the archive SHA-256 from a trusted publisher; a checksum is not a signature. HTTP and HTTPS are supported. Installation does not select or start the runtime."))
                            .font(MTTheme.body(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(L("A runtime is a folder with llama-server, its libraries and a runtime.json manifest. The bundled engine is always available and cannot be removed."))
                            .font(MTTheme.body(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Hugging Face API Token
                MTCard(title: L("Hugging Face API Token"), systemImage: "key.fill", accent: MTTheme.amber) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        Text(L("A Hugging Face token is optional, but increases API rate limits and allows downloading gated models."))
                            .font(MTTheme.body(11))
                            .foregroundStyle(MTTheme.textSecondary)

                        HStack {
                            SecureField(L("hf_... token"), text: $hfToken)
                                .textFieldStyle(.roundedBorder)
                                .font(MTTheme.body(12))

                            Button(L("Save Token")) {
                                saveToken()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MTTheme.amber)
                            .disabled(hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if store.hfTokenConfigured {
                                Button(L("Remove")) {
                                    do {
                                        try store.setHuggingFaceToken(nil)
                                        hfToken = ""
                                        tokenError = nil
                                    } catch {
                                        tokenError = error.localizedDescription
                                    }
                                }
                                .buttonStyle(.bordered)
                                .foregroundStyle(MTTheme.danger)
                            }
                        }

                        if let tokenError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(MTTheme.danger)
                                Text(tokenError)
                                    .font(MTTheme.body(10))
                                    .foregroundStyle(MTTheme.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if showingTokenSaved {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(MTTheme.emerald)
                                Text(L("Saved."))
                                    .font(MTTheme.body(10))
                                    .foregroundStyle(MTTheme.emerald)
                            }
                        } else if store.hfTokenConfigured {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(MTTheme.emerald)
                                Text(L("Active token securely stored in macOS Keychain."))
                                    .font(MTTheme.body(10))
                                    .foregroundStyle(MTTheme.emerald)
                            }
                        }
                    }
                }

                // Gateway & Loopback Ports
                MTCard(title: L("Gateway & Loopback Integration"), systemImage: "network", accent: MTTheme.emerald) {
                    VStack(alignment: .leading, spacing: MTTheme.s3) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Unified OpenAI Gateway Port"))
                                    .font(MTTheme.body(12, weight: .semibold))
                                    .foregroundStyle(MTTheme.textPrimary)
                                Text("http://127.0.0.1:18317/v1")
                                    .font(MTTheme.body(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            Spacer()
                            MTStatusPill(
                                text: gateway.isRunning ? L("Listening") : L("Stopped"),
                                status: gateway.isRunning ? .ok : .idle
                            )
                        }

                        Divider().background(Color.primary.opacity(0.08))

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Internal llama-server Port"))
                                    .font(MTTheme.body(12, weight: .semibold))
                                    .foregroundStyle(MTTheme.textPrimary)
                                Text("http://127.0.0.1:\(runtime.port)/v1 " + L("(Loopback auth enabled)"))
                                    .font(MTTheme.body(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            Spacer()
                            if runtime.status.isRunning {
                                MTStatusPill(text: L("Active"), status: .ok)
                            } else {
                                MTStatusPill(text: L("Standby"), status: .idle)
                            }
                        }
                    }
                }
            }
            .padding(MTTheme.s4)
        }
        .onAppear {
            if let token = LocalKeychainHelper.loadHuggingFaceToken() {
                hfToken = token
            }
        }
        .confirmationDialog(
            L("Use this folder for models?"),
            isPresented: Binding(
                get: { pendingStorageURL != nil },
                set: { if !$0 { pendingStorageURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Move existing models here")) {
                if let url = pendingStorageURL { Task { await adoptStorage(url, migrate: true) } }
            }
            Button(L("Use folder without moving")) {
                if let url = pendingStorageURL { Task { await adoptStorage(url, migrate: false) } }
            }
            Button(L("Cancel"), role: .cancel) { pendingStorageURL = nil }
        } message: {
            Text(pendingStorageURL?.path ?? "")
        }
        .sheet(isPresented: $showingRuntimeCatalog) {
            RuntimeCatalogSheet(runtimeStore: runtimeStore)
        }
        .confirmationDialog(
            L("Delete Runtime?"),
            isPresented: Binding(
                get: { pendingRuntimeDelete != nil },
                set: { if !$0 { pendingRuntimeDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                if let manifest = pendingRuntimeDelete {
                    pendingRuntimeDelete = nil
                    deleteRuntime(manifest)
                }
            }
            Button(L("Cancel"), role: .cancel) { pendingRuntimeDelete = nil }
        } message: {
            if let manifest = pendingRuntimeDelete {
                Text(String(
                    format: L("Delete runtime %@? Its files will be removed from disk."),
                    manifest.build
                ))
            }
        }
        .alert(
            L("Could not delete runtime"),
            isPresented: Binding(
                get: { runtimeDeleteError != nil },
                set: { if !$0 { runtimeDeleteError = nil } }
            )
        ) {
            Button(L("OK")) { runtimeDeleteError = nil }
        } message: {
            Text(runtimeDeleteError ?? "")
        }
    }

    /// Picks a folder and asks what to do with the existing models: adopting a
    /// folder between two models would otherwise make every model look missing
    /// (or, worse, bind a registry entry to a stranger's file with the same name).
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("Select Models Directory")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingStorageURL = url
    }

    private var storageIssueText: String? {
        switch store.storageStatus {
        case .internalStorage, .available:
            return nil
        case .unavailable:
            return L("The models folder is not available. Reconnect the drive or choose another folder.")
        case .differentVolume:
            return L("This folder belongs to a different drive than the one recorded. Models may be missing or belong to another installation.")
        case .readOnly:
            return L("The models folder is read-only. Downloads and imports will fail.")
        }
    }

    private var runtimeProvenanceLabel: String {
        guard let resolved = runtime.resolvedRuntime else { return L("Not found") }
        switch resolved.provenance {
        case .customBinary: return L("External (chosen file)")
        case .system: return L("External (system install)")
        case .packaged(let manifest):
            return manifest.isBundled ? L("Bundled") : L("Downloaded runtime")
        }
    }

    private func saveToken() {
        do {
            try store.setHuggingFaceToken(hfToken.isEmpty ? nil : hfToken)
            tokenError = nil
            showingTokenSaved = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showingTokenSaved = false
            }
        } catch {
            tokenError = error.localizedDescription
            showingTokenSaved = false
        }
    }

    private func adoptStorage(_ url: URL, migrate: Bool) async {
        guard !storageBusy else { return }
        storageBusy = true
        storageError = nil
        defer {
            storageBusy = false
            pendingStorageURL = nil
        }
        do {
            if migrate {
                try await store.migrateModelsDirectory(to: url, deleteSource: false)
            } else {
                try store.connectModelsDirectory(url)
            }
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func useInternalStorage() async {
        guard !storageBusy else { return }
        storageBusy = true
        storageError = nil
        defer { storageBusy = false }
        do {
            try store.connectModelsDirectory(nil)
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Engine scheduling values live in UserDefaults: the router reads them on
    /// start, so changing one takes effect after a restart of the engine.
    private var parallelRequests: Binding<Int> {
        Binding(
            get: { LocalInferenceService.parallelRequests },
            set: { UserDefaults.standard.set($0, forKey: "localAIParallel") }
        )
    }

    private var idleUnload: Binding<Int> {
        Binding(
            get: { LocalInferenceService.idleUnloadSeconds },
            set: { UserDefaults.standard.set($0, forKey: "localAIIdleUnloadSeconds") }
        )
    }

    private var modelsMax: Binding<Int> {
        Binding(
            get: { LocalInferenceService.modelsMaxConcurrent },
            set: { UserDefaults.standard.set($0, forKey: "localAIModelsMax") }
        )
    }

    /// Label on the left, control on the right, consistent with the model
    /// settings sheet.
    private func settingRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: MTTheme.s3) {
            Text(title)
                .font(MTTheme.body(11.5))
                .foregroundStyle(MTTheme.textSecondary)
            Spacer(minLength: MTTheme.s3)
            control()
        }
    }

    @ViewBuilder
    private func runtimeRow(_ manifest: RuntimeManifest) -> some View {
        let isActive = runtimeStore.active?.id == manifest.id
        HStack(spacing: MTTheme.s3) {
            Button {
                runtimeStore.select(manifest)
                Task { await LocalInferenceService.shared.applySettingsChange() }
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? MTTheme.emerald : MTTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(manifest.build)
            .accessibilityValue(isActive ? L("Selected") : L("Not selected"))
            .accessibilityAddTraits(isActive ? [.isSelected] : [])

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(manifest.backend.uppercased())
                        .font(MTTheme.body(10.5, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(manifest.build)
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textTertiary)
                    if manifest.isBundled {
                        Text(L("Bundled"))
                            .font(MTTheme.body(9))
                            .foregroundStyle(MTTheme.emerald)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(MTTheme.emerald.opacity(0.12), in: Capsule())
                    }
                }
                Text("\(manifest.platform) · \(LocalHardwareService.formatBytes(manifest.sizeBytes)) · \(L(runtimeStore.integrity(of: manifest)))")
                    .font(MTTheme.mono(9.5))
                    .foregroundStyle(MTTheme.textTertiary)
            }
            Spacer(minLength: 0)

            if !manifest.isBundled {
                Button {
                    pendingRuntimeDelete = manifest
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(MTTheme.danger)
                }
                .buttonStyle(.plain)
                .help(L("Delete runtime"))
                .accessibilityLabel(L("Delete runtime"))
            }
        }
        .padding(.vertical, 3)
    }

    /// Copies a runtime folder into the managed directory and rescans.
    private func deleteRuntime(_ manifest: RuntimeManifest) {
        if runtime.status.isRunning, runtimeStore.active?.id == manifest.id {
            runtimeDeleteError = L("Stop the engine before deleting the active runtime.")
            return
        }
        do {
            try runtimeStore.delete(manifest)
        } catch {
            runtimeDeleteError = error.localizedDescription
        }
    }

    private func addRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add Runtime")
        panel.message = L("Select a runtime folder containing llama-server and runtime.json:")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                runtimeActionError = nil
                runtimeStore.importFolder(url)
            }
        }
    }

    private func engineFact(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(MTTheme.body(9.5, weight: .semibold))
                .foregroundStyle(MTTheme.textTertiary)
                .textCase(.uppercase)
            Text(value)
                .font(MTTheme.body(10.5, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }

    private func chooseServerBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Select llama-server Binary")

        if panel.runModal() == .OK, let url = panel.url {
            runtime.customBinaryPath = url.path
        }
    }
}
