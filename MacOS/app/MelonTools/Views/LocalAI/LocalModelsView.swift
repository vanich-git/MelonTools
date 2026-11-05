import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LocalModelsView: View {
    @ObservedObject var store = LocalModelStore.shared
    @ObservedObject var runtime = LocalInferenceService.shared
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var settingsModel: LocalModel?
    @State private var testModel: LocalModel?
    @State private var modelToDelete: LocalModel?
    @State private var pendingStartModel: LocalModel?
    @State private var importError: String?
    @State private var deletionWarning: String?
    /// Guards against a second delete while the engine is being drained.
    @State private var isDeleting = false
    /// True while a copy or a folder scan runs off the main thread.
    @State private var isImporting = false

    var filteredModels: [LocalModel] {
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return store.models
        }
        let q = search.lowercased()
        return store.models.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.id.lowercased().contains(q) ||
            $0.quantization.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack(spacing: MTTheme.s3) {
                // Search box
                HStack(spacing: MTTheme.s2) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(MTTheme.textTertiary)
                    TextField(L("Search installed models..."), text: $search)
                        .textFieldStyle(.plain)
                        .font(MTTheme.body(12))
                        .focused($searchFocused)
                        .onExitCommand {
                            if !search.isEmpty { search = "" } else { searchFocused = false }
                        }
                    if !search.isEmpty {
                        Button(action: { search = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MTTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Clear search"))
                    }
                }
                .padding(.horizontal, MTTheme.s3)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
                .frame(maxWidth: 300)

                Spacer()

                // Total size indicator
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.caption)
                    Text(String(format: L("%.1f GB total"), Double(store.totalDiskBytes) / 1_073_741_824.0))
                        .font(MTTheme.body(11, weight: .medium))
                }
                .foregroundStyle(MTTheme.textTertiary)

                // Import button
                Button(action: { openImportPanel(folder: false) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text(L("Import .gguf..."))
                    }
                    .font(MTTheme.body(11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(isImporting)
            }
            .padding(.horizontal, MTTheme.s4)
            .padding(.vertical, MTTheme.s3)
            .background(Color.primary.opacity(0.02))

            if let err = importError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(MTTheme.danger)
                    Text(err)
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.danger)
                    Spacer()
                    Button(action: { importError = nil }) {
                        Image(systemName: "xmark")
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Dismiss"))
                }
                .padding(.horizontal, MTTheme.s4)
                .padding(.top, MTTheme.s2)
            }

            Divider().background(Color.primary.opacity(0.06))

            // Models list or empty state
            if store.models.isEmpty {
                emptyState
            } else if filteredModels.isEmpty {
                VStack(spacing: MTTheme.s2) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(MTTheme.textTertiary)
                    Text(L("No models match your search"))
                        .font(MTTheme.body(12, weight: .medium))
                        .foregroundStyle(MTTheme.textSecondary)
                    Button(L("Clear search")) { search = "" }
                        .buttonStyle(.plain)
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.cyan)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: MTTheme.s3) {
                        ForEach(filteredModels) { model in
                            modelCard(model)
                        }
                    }
                    .padding(MTTheme.s4)
                }
            }
        }
        .background(
            // Cmd-F is the platform convention for "focus the search field";
            // the HF catalog had it and this screen did not.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .sheet(item: $settingsModel) { m in
            LocalModelSettingsSheet(model: Binding(
                get: { store.models.first(where: { $0.id == m.id }) ?? m },
                set: { store.addOrUpdateModel($0) }
            ))
        }
        .sheet(item: $testModel) { m in
            LocalModelTestSheet(model: m)
        }
        .confirmationDialog(
            L("Delete Model?"),
            isPresented: Binding(get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Delete Model and File"), role: .destructive) {
                guard let model = modelToDelete else { return }
                modelToDelete = nil
                Task { await deleteModel(model) }
            }
            .disabled(isDeleting)
            Button(L("Cancel"), role: .cancel) {
                modelToDelete = nil
            }
        } message: {
            if let m = modelToDelete {
                Text(String(format: L("Are you sure you want to delete '%@' and remove its .gguf file from disk?"), m.displayName))
            }
        }
        .alert(
            L("Some model files were not deleted"),
            isPresented: Binding(
                get: { deletionWarning != nil },
                set: { if !$0 { deletionWarning = nil } }
            )
        ) {
            Button(L("OK")) { deletionWarning = nil }
        } message: {
            Text(deletionWarning ?? "")
        }
        .confirmationDialog(
            L("Switch Model?"),
            isPresented: Binding(
                get: { pendingStartModel != nil },
                set: { if !$0 { pendingStartModel = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("Stop current and load")) {
                if let model = pendingStartModel {
                    pendingStartModel = nil
                    performStart(model)
                }
            }
            Button(L("Cancel"), role: .cancel) { pendingStartModel = nil }
        } message: {
            if let pending = pendingStartModel, let current = runtime.currentModel {
                Text(String(
                    format: L("%@ is running. Stop it and load %@?"),
                    current.displayName, pending.displayName
                ))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MTTheme.s4) {
            Spacer()
            Image(systemName: "cpu")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(MTTheme.emerald.opacity(0.6))
            
            VStack(spacing: MTTheme.s2) {
                Text(L("No Local Models Installed"))
                    .font(MTTheme.body(16, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                Text(L("Download models from Hugging Face or import existing .gguf files."))
                    .font(MTTheme.body(12))
                    .foregroundStyle(MTTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: MTTheme.s3) {
                if isImporting {
                    // Import runs in the background; show that instead of
                    // letting the button look clickable.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.8)
                        Text(L("Importing..."))
                            .font(MTTheme.body(11.5))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                } else {
                    Button(action: { openImportPanel(folder: false) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                            Text(L("Import .gguf File..."))
                        }
                    }
                    .buttonStyle(.bordered)

                    // A split model or a folder of models is imported in one go.
                    Button(action: { openImportPanel(folder: true) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                            Text(L("Import Folder..."))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MTTheme.s4)
    }

    private func modelCard(_ model: LocalModel) -> some View {
        let isRunningThis = runtime.status.isRunning && runtime.currentModel?.id == model.id
        let isStartingThis = isStarting(model)
        // Only one engine can come up at a time, so the other cards lock their
        // Start button while a launch is in flight.
        let isBusy = runtime.status.isStarting

        return MTCard(accent: isRunningThis ? MTTheme.emerald : (isStartingThis ? MTTheme.amber : nil)) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                // Header row
                HStack(alignment: .top, spacing: MTTheme.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.displayName)
                                .font(MTTheme.body(13.5, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                            
                            if isRunningThis {
                                Text(L("ACTIVE"))
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(MTTheme.emerald)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(MTTheme.emerald.opacity(0.15))
                                    .cornerRadius(4)
                            }

                            if isStartingThis {
                                HStack(spacing: 3) {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.65)
                                        .frame(width: 9, height: 9)
                                    Text(L("LOADING"))
                                        .font(.system(size: 9.5, weight: .bold))
                                }
                                .foregroundStyle(MTTheme.amber)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MTTheme.amber.opacity(0.15))
                                .cornerRadius(4)
                            }
                        }

                        Text(model.id)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(MTTheme.textSecondary)
                    }

                    Spacer()

                    // Status and action buttons
                    HStack(spacing: 8) {
                        if isStartingThis {
                            // The engine needs up to a minute to map the weights
                            // and answer /health; without this the button looked
                            // dead the whole time.
                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.7)
                                    .frame(width: 11, height: 11)
                                Text(L("Starting..."))
                            }
                            .font(MTTheme.body(11, weight: .medium))
                            .foregroundStyle(MTTheme.amber)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(MTTheme.amber.opacity(0.12), in: Capsule())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(L("Starting..."))
                        } else if isRunningThis {
                            Button(action: { stopModel() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "stop.fill")
                                    Text(L("Stop"))
                                }
                                .font(MTTheme.body(11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(action: { startModel(model) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.fill")
                                    Text(L("Start"))
                                }
                                .font(MTTheme.body(11, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MTTheme.emerald)
                            .disabled(isBusy)
                        }

                        Button(action: { testModel = model }) {
                            Image(systemName: "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .help(L("Test Model"))
                        .accessibilityLabel(L("Test Model"))

                        Button(action: { settingsModel = model }) {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.bordered)
                        .help(L("Settings"))
                        .accessibilityLabel(L("Settings"))

                        MTMenuButton(systemImage: "ellipsis", entries: [
                            .item(L("Copy API Model ID"), systemImage: "doc.on.doc") {
                                copyModelID(model)
                            },
                            .item(L("Show in Finder"), systemImage: "folder") {
                                showInFinder(model)
                            },
                            .divider,
                            .item(L("Delete Model"), systemImage: "trash", destructive: true) {
                                guard !isDeleting else { return }
                                modelToDelete = model
                            }
                        ])
                    }
                }

                Divider().background(Color.primary.opacity(0.06))

                // Metadata row
                HStack(spacing: MTTheme.s4) {
                    metadataBadge(icon: "archivebox", text: model.quantization)
                    metadataBadge(icon: "internaldrive", text: String(format: L("%.2f GB"), Double(model.fileSize) / 1_073_741_824.0))
                    metadataBadge(icon: "text.book.closed", text: "\(model.userSettings.contextLength) ctx")
                    // The runtime a model is bound to (§13.3). It follows the
                    // active runtime at launch, so the card reports what will
                    // actually serve it.
                    metadataBadge(
                        icon: "square.stack.3d.up",
                        text: model.backend.rawValue
                    )
                    if let architecture = model.architecture, !architecture.isEmpty {
                        metadataBadge(icon: "cpu", text: architecture)
                    }
                    if model.capabilities.contains(.tools) {
                        metadataBadge(icon: "wrench.and.screwdriver", text: "Tools")
                    }
                    if model.capabilities.contains(.vision) {
                        metadataBadge(icon: "photo", text: "Vision")
                    }
                    Spacer()
                }

                // Indeterminate bar: llama-server reports no progress while it
                // loads weights, but something has to move on screen.
                if isStartingThis {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(MTTheme.amber)
                }

                if let failure = failureMessage(for: model) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(failure)
                            .font(MTTheme.body(10.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(MTTheme.danger)
                }
            }
        }
    }

    /// True while this exact model is being loaded into the engine.
    private func isStarting(_ model: LocalModel) -> Bool {
        if case .starting(let modelId) = runtime.status {
            return modelId == model.id
        }
        return false
    }

    /// Launch failure attributed to this card, if the engine rejected it.
    private func failureMessage(for model: LocalModel) -> String? {
        guard case .failed(let message) = runtime.status else { return nil }
        guard runtime.failedModelId == model.id else { return nil }
        return message
    }

    private func metadataBadge(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(MTTheme.body(11))
        }
        .foregroundStyle(MTTheme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(4)
    }

    private func startModel(_ model: LocalModel) {
        // The router keeps one model by default. Switching has to be a choice,
        // not a side effect of pressing Start on another card.
        if runtime.status.isRunning,
           let current = runtime.currentModel,
           current.id != model.id {
            pendingStartModel = model
            return
        }
        performStart(model)
    }

    private func performStart(_ model: LocalModel) {
        Task {
            do {
                try await runtime.loadModel(model)
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                }
            }
        }
    }

    private func stopModel() {
        Task {
            await runtime.stop()
        }
    }

    /// Copies the exact identifier a client must send in `model`. Users
    /// otherwise guess between the display name and the alias (§6.3).
    private func copyModelID(_ model: LocalModel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.id, forType: .string)
    }

    private func showInFinder(_ model: LocalModel) {
        let fileURL = model.primaryFileURL(in: store.modelsDirectory)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            importError = L("File not found on disk: ") + fileURL.path
        }
    }

    /// Deletes a model and its files.
    ///
    /// The engine is drained first: on macOS `unlink` does not release pages
    /// that are already mapped, so a running router kept serving a deleted model
    /// and a re-import of the same path failed. The store then moves the files
    /// aside and only commits the registry removal when that worked.
    private func deleteModel(_ model: LocalModel) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        await runtime.releaseModelFiles(model)
        let failed = store.removeModel(id: model.id, deleteFiles: true)
        // The catalog is part of the gateway contract: a deleted model must not
        // stay advertised in config.yaml until some later restart.
        try? CodexGatewayService.shared.writeConfig()
        if !failed.isEmpty {
            deletionWarning = String(
                format: L("Model removed, but %d file(s) could not be deleted: %@"),
                failed.count,
                failed.joined(separator: ", ")
            )
        }
    }

    /// Imports a single `.gguf` or a whole folder. A folder may contain split
    /// models (`-00001-of-00003.gguf`), which become one registry entry each.
    ///
    /// The panel is opened asynchronously and the copy runs on a background
    /// task: a modal panel plus a main-thread copy of a multi-gigabyte file
    /// froze the whole window.
    private func openImportPanel(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = false
        if !folder {
            panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        }
        panel.prompt = L("Import GGUF")
        panel.message = folder
            ? L("Select a folder with .gguf files to import into Melon Tools:")
            : L("Select a .gguf model file to import into Melon Tools:")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                isImporting = true
                defer { isImporting = false }
                do {
                    if folder {
                        _ = try await store.importGGUFFolderAsync(from: url)
                    } else {
                        _ = try await store.importGGUFFileAsync(from: url)
                    }
                    importError = nil
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
    }
}
