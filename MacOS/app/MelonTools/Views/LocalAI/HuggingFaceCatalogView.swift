import SwiftUI
import AppKit

/// Immutable identity of one catalog page request.
///
/// The snapshot is taken when the request starts: the list keeps showing the
/// query it was built for, so "Load more" can never append a page of the text
/// currently typed into the field, and a completion can be matched against the
/// query it belongs to instead of the live UI state.
struct HFSearchRequest: Equatable {
    let query: String
    let sort: HuggingFaceService.SortOrder
    let offset: Int
    let generation: Int

    /// `offset` is deliberately ignored: the first page and every "Load more"
    /// page belong to the same search identity.
    func belongs(to other: HFSearchRequest?) -> Bool {
        guard let other else { return false }
        return query == other.query && sort == other.sort && generation == other.generation
    }
}

struct HuggingFaceCatalogView: View {
    @ObservedObject var downloads = LocalDownloadManager.shared
    @ObservedObject var store = LocalModelStore.shared
    /// False while another Local AI tab is on screen. Kept as a stored
    /// property so the screen can stay mounted and keep its `@State`.
    var isActive: Bool = true

    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var isSearching = false
    @State private var searchResults: [HFModelSearchResult] = []
    @State private var sortOrder: HuggingFaceService.SortOrder = .downloads
    @State private var isLoadingMore = false
    /// A pasted link or repo id, resolved before a free-text search runs.
    @State private var pastedLink = ""
    @State private var selectedRepo: HFModelSearchResult?
    @State private var repoDetails: HFModelDetails?
    @State private var isLoadingDetails = false
    /// Two inline errors: the list owns search/pagination failures, the detail
    /// pane owns repository failures. A search error used to be written into a
    /// shared message that the right pane only renders when a repo is selected,
    /// so it was invisible exactly when it mattered.
    @State private var searchError: String?
    @State private var detailsError: String?
    @State private var hasSearched = false
    /// Incremented for every search so a slow, older response cannot overwrite
    /// the results of the query the user typed last.
    @State private var searchGeneration = 0
    /// Identity of the results currently on screen. `Load more` and every
    /// completion use it instead of the live search field.
    @State private var activeRequest: HFSearchRequest?
    @State private var searchTask: Task<Void, Never>?
    @State private var detailsTask: Task<Void, Never>?
    @State private var showTokenSheet = false
    @State private var hfToken = LocalKeychainHelper.loadHuggingFaceToken() ?? ""

    private let presetSearches = [
        "Qwen2.5-Coder", "Llama-3.2", "DeepSeek-R1-Distill", "Mistral", "Gemma-2", "Phi-3.5"
    ]

    var body: some View {
        HSplitView {
            // Left pane: search and repo list
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: MTTheme.s2) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(MTTheme.textTertiary)
                    TextField(L("Search Hugging Face (e.g. Qwen2.5, Llama-3)..."), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(MTTheme.body(12))
                        .focused($searchFocused)
                        .onSubmit { performSearch() }
                        .onExitCommand {
                            if !searchQuery.isEmpty {
                                clearSearch()
                            } else {
                                searchFocused = false
                            }
                        }

                    if isSearching {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    } else if !searchQuery.isEmpty {
                        Button(action: { clearSearch() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(MTTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Clear search"))
                    }

                    Button(L("Search")) {
                        performSearch()
                    }
                    .buttonStyle(.bordered)
                    .font(MTTheme.body(11, weight: .medium))
                    .disabled(isSearching)

                    Button(action: { showTokenSheet = true }) {
                        Image(systemName: "key")
                    }
                    .buttonStyle(.bordered)
                    .help(L("Hugging Face API Token"))
                    .accessibilityLabel(L("Hugging Face API Token"))
                }
                .padding(.horizontal, MTTheme.s4)
                .padding(.vertical, MTTheme.s3)
                .background(Color.primary.opacity(0.02))
                .background {
                    // Cmd-F belongs to the screen the user is looking at: a
                    // mounted-but-hidden tab must not steal the shortcut.
                    if isActive {
                        Button("") { searchFocused = true }
                            .keyboardShortcut("f", modifiers: .command)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }

                // Quick preset pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presetSearches, id: \.self) { preset in
                            Button(preset) {
                                searchQuery = preset
                                performSearch()
                            }
                            .buttonStyle(.plain)
                            .font(MTTheme.body(10.5))
                            .foregroundStyle(MTTheme.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MTTheme.cyan.opacity(0.1))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal, MTTheme.s4)
                    .padding(.vertical, 6)
                }
                .background(Color.primary.opacity(0.01))

                Divider().background(Color.primary.opacity(0.06))

                // Search/pagination failures stay in the list pane, where the
                // user is looking, instead of a shared banner the detail pane
                // only renders once a repository is selected.
                if let searchError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.top, 1)
                        Text(searchError)
                            .font(MTTheme.body(11))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(L("Retry")) { performSearch() }
                            .buttonStyle(.plain)
                            .font(MTTheme.body(10.5, weight: .semibold))
                            .foregroundStyle(MTTheme.cyan)
                    }
                    .foregroundStyle(MTTheme.danger)
                    .padding(.horizontal, MTTheme.s4)
                    .padding(.vertical, 6)
                    .background(MTTheme.danger.opacity(0.09))
                }

                // Search Results
                if searchResults.isEmpty && !isSearching && searchError == nil {
                    VStack(spacing: MTTheme.s3) {
                        Spacer()
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 36))
                            .foregroundStyle(MTTheme.cyan.opacity(0.5))
                        Text(hasSearched
                             ? L("No models found. Try another query.")
                             : L("Search Hugging Face for GGUF models"))
                            .font(MTTheme.body(13, weight: .medium))
                            .foregroundStyle(MTTheme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(searchResults, selection: $selectedRepo) { repo in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(repo.displayName)
                                .font(MTTheme.body(12, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                            Text(repo.id)
                                .font(MTTheme.body(10))
                                .foregroundStyle(MTTheme.textTertiary)
                                .lineLimit(1)
                            HStack(spacing: MTTheme.s3) {
                                if let dl = repo.downloads {
                                    Label("\(dl)", systemImage: "arrow.down")
                                }
                                if let lk = repo.likes {
                                    Label("\(lk)", systemImage: "heart")
                                }
                            }
                            .font(MTTheme.body(10))
                            .foregroundStyle(MTTheme.textTertiary)
                        }
                        .padding(.vertical, 4)
                        .tag(repo)
                    }
                    .listStyle(.inset)

                    // Pagination: Hugging Face returns pages, so the user asks
                    // for more instead of the app loading the whole index.
                    if !searchResults.isEmpty {
                        Button {
                            loadMore()
                        } label: {
                            HStack(spacing: MTTheme.s2) {
                                if isLoadingMore {
                                    ProgressView().scaleEffect(0.55).frame(width: 12, height: 12)
                                }
                                Text(isLoadingMore ? L("Loading...") : L("Load more"))
                                    .font(MTTheme.body(11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MTTheme.cyan)
                        .disabled(isLoadingMore)
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320)

            // Right pane: repo details and downloadable files
            VStack(spacing: 0) {
                if let repo = selectedRepo {
                    repoDetailsView(repo)
                } else {
                    VStack(spacing: MTTheme.s2) {
                        Spacer()
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 36))
                            .foregroundStyle(MTTheme.textTertiary)
                        Text(L("Select a model repository from the list"))
                            .font(MTTheme.body(13))
                            .foregroundStyle(MTTheme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
        .onChange(of: selectedRepo) { _, newRepo in
            if let repo = newRepo {
                loadRepoDetails(repo.id)
            } else {
                detailsTask?.cancel()
                detailsTask = nil
                repoDetails = nil
                detailsError = nil
                isLoadingDetails = false
            }
        }
        .sheet(isPresented: $showTokenSheet) {
            tokenSheetView
        }
        .onDisappear {
            searchTask?.cancel()
            detailsTask?.cancel()
        }
    }

    /// Short, locale-aware date for the catalog header.
    private static func shortDate(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: iso)
        }
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func repoDetailsView(_ repo: HFModelSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: MTTheme.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.displayName)
                        .font(MTTheme.body(14, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(repo.id)
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textTertiary)
                    HStack(spacing: MTTheme.s3) {
                        if let dl = repo.downloads {
                            Text("\(dl) " + L("downloads"))
                        }
                        if let lk = repo.likes {
                            Text("\(lk) " + L("likes"))
                        }
                        // Missing values stay hidden: the spec forbids inventing
                        // data that Hugging Face did not return (§7.3).
                        if let updated = repo.lastModified, let short = Self.shortDate(updated) {
                            Text(L("Updated") + " " + short)
                        }
                        if repo.privateRepo == true || repo.gated == true {
                            Label(L("Gated"), systemImage: "lock.fill")
                                .foregroundStyle(MTTheme.amber)
                        }
                    }
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
                Button(action: {
                    if let url = URL(string: "https://huggingface.co/\(repo.id)") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text(L("Open on HF"))
                    }
                    .font(MTTheme.body(11))
                }
                .buttonStyle(.bordered)
            }
            .padding(MTTheme.s4)
            .background(Color.primary.opacity(0.02))

            Divider().background(Color.primary.opacity(0.06))

            // Files list
            if isLoadingDetails {
                VStack(spacing: MTTheme.s3) {
                    Spacer()
                    ProgressView()
                    Text(L("Fetching GGUF files and hardware estimation..."))
                        .font(MTTheme.body(12))
                        .foregroundStyle(MTTheme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = detailsError {
                VStack(spacing: MTTheme.s3) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(MTTheme.danger)
                    Text(err)
                        .font(MTTheme.body(12))
                        .foregroundStyle(MTTheme.danger)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let details = repoDetails {
                if details.ggufFiles.isEmpty {
                    VStack(spacing: MTTheme.s3) {
                        Spacer()
                        Text(L("No GGUF files found in this repository."))
                            .font(MTTheme.body(12))
                            .foregroundStyle(MTTheme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: MTTheme.s3) {
                            ForEach(details.ggufFiles) { file in
                                fileCard(file, repoId: details.id)
                            }
                        }
                        .padding(MTTheme.s4)
                    }
                }
            }
        }
    }

    private func fileCard(_ file: HFGGUFFile, repoId: String) -> some View {
        let isDownloading = downloads.items.contains { item in
            item.repoId == repoId && item.rfilename == file.rfilename &&
            (item.state == .downloading || item.state == .queued || item.state == .paused)
        }
        // Stored files live in a per-model namespace now, so the comparison is
        // by file name, not by the whole relative path.
        let baseName = (file.rfilename as NSString).lastPathComponent
        let isInstalled = store.models.contains { model in
            model.repoId == repoId && model.files.contains {
                ($0 as NSString).lastPathComponent == baseName
            }
        }

        return MTCard {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.rfilename)
                            .font(MTTheme.body(12.5, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: MTTheme.s3) {
                            Text(file.formattedSize)
                            Text(file.quantization)
                        }
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textSecondary)
                    }

                    Spacer()

                    // Compatibility badge
                    compatibilityBadge(file.estimation.recommendation)

                    // Download / Installed action
                    if isInstalled {
                        Text(L("Installed"))
                            .font(MTTheme.body(11, weight: .semibold))
                            .foregroundStyle(MTTheme.emerald)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MTTheme.emerald.opacity(0.12))
                            .cornerRadius(4)
                    } else if isDownloading {
                        Text(L("Downloading..."))
                            .font(MTTheme.body(11, weight: .semibold))
                            .foregroundStyle(MTTheme.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MTTheme.cyan.opacity(0.12))
                            .cornerRadius(4)
                    } else {
                        Button(action: { startDownload(file, repoId: repoId) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text(L("Download"))
                            }
                            .font(MTTheme.body(11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(MTTheme.emerald)
                    }
                }
            }
        }
    }

    private func compatibilityBadge(_ rec: CompatibilityRecommendation) -> some View {
        let (color, text): (Color, String) = {
            switch rec {
            case .recommended: return (MTTheme.emerald, L("Recommended"))
            case .fitsWithLimitations: return (MTTheme.gold, L("Fits with limits"))
            case .highMemoryUsage: return (MTTheme.amber, L("High RAM"))
            case .insufficientMemory: return (MTTheme.danger, L("Low Memory"))
            case .unsupportedArchitecture: return (MTTheme.danger, L("Unsupported"))
            case .unknown: return (MTTheme.textTertiary, L("Unknown"))
            }
        }()

        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(MTTheme.body(10.5, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(4)
    }

    private var tokenSheetView: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            HStack {
                Text(L("Hugging Face API Token"))
                    .font(MTTheme.body(14, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                Spacer()
                Button(action: { showTokenSheet = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MTTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            Text(L("An API token is required to download gated or private models (such as Llama 3, Gemma). It is securely stored in your macOS Keychain."))
                .font(MTTheme.body(11.5))
                .foregroundStyle(MTTheme.textSecondary)

            SecureField("hf_...", text: $hfToken)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(L("Get Token on Hugging Face")) {
                    if let url = URL(string: "https://huggingface.co/settings/tokens") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(MTTheme.body(11))
                .foregroundStyle(MTTheme.cyan)

                Spacer()

                Button(L("Cancel")) {
                    showTokenSheet = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(L("Save Token")) {
                    let trimmed = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        _ = LocalKeychainHelper.deleteHuggingFaceToken()
                    } else {
                        _ = LocalKeychainHelper.saveHuggingFaceToken(trimmed)
                    }
                    showTokenSheet = false
                }
                .buttonStyle(.borderedProminent)
                .tint(MTTheme.emerald)
            }
        }
        .padding(MTTheme.s4)
        .frame(width: 440)
        .background(MTTheme.background)
    }

    private func performSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        searchTask?.cancel()
        detailsTask?.cancel()

        searchGeneration += 1
        let request = HFSearchRequest(
            query: q,
            sort: sortOrder,
            offset: 0,
            generation: searchGeneration
        )
        activeRequest = request
        isSearching = true
        isLoadingMore = false
        hasSearched = true
        searchError = nil
        detailsError = nil
        selectedRepo = nil
        repoDetails = nil
        isLoadingDetails = false
        searchResults = []

        let token = LocalKeychainHelper.loadHuggingFaceToken()
        searchTask = Task { @MainActor in
            do {
                let results = try await HuggingFaceService.searchModels(
                    query: request.query,
                    sort: request.sort,
                    offset: request.offset,
                    token: token
                )
                guard self.isCurrent(request) else { return }
                self.searchResults = results
                self.isSearching = false
            } catch {
                guard self.isCurrent(request) else { return }
                self.searchError = Self.message(for: error)
                self.isSearching = false
            }
        }
    }

    /// Drops the query, invalidates every in-flight page and cancels the
    /// requests. Without the generation bump a late response could repopulate
    /// the list after the user cleared it.
    private func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        detailsTask?.cancel()
        detailsTask = nil

        searchGeneration += 1
        activeRequest = nil
        searchResults = []
        searchQuery = ""
        hasSearched = false
        isSearching = false
        isLoadingMore = false
        searchError = nil
        detailsError = nil
        selectedRepo = nil
        repoDetails = nil
        isLoadingDetails = false
    }

    /// Loads the next page and appends it, keeping the current list usable.
    ///
    /// The page identity comes from `activeRequest`, not from the search field:
    /// typing a new query without submitting must not change what "Load more"
    /// continues.
    private func loadMore() {
        guard let active = activeRequest, !isSearching, !isLoadingMore else { return }
        let request = HFSearchRequest(
            query: active.query,
            sort: active.sort,
            offset: searchResults.count,
            generation: active.generation
        )
        isLoadingMore = true
        searchError = nil
        let token = LocalKeychainHelper.loadHuggingFaceToken()

        searchTask = Task { @MainActor in
            do {
                let page = try await HuggingFaceService.searchModels(
                    query: request.query,
                    sort: request.sort,
                    offset: request.offset,
                    token: token
                )
                guard self.isCurrent(request) else { return }
                // The API can repeat an entry across pages; keep the list unique.
                let known = Set(self.searchResults.map(\.id))
                self.searchResults += page.filter { !known.contains($0.id) }
                self.isLoadingMore = false
            } catch {
                guard self.isCurrent(request) else { return }
                self.searchError = Self.message(for: error)
                self.isLoadingMore = false
            }
        }
    }

    /// A completion is applied only when it still belongs to the request the
    /// list shows — success and failure alike.
    private func isCurrent(_ request: HFSearchRequest) -> Bool {
        !Task.isCancelled && request.belongs(to: activeRequest)
    }

    private static func message(for error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? L("The request failed.") : text
    }

    /// Opens a repository by `owner/repo`, so a pasted link works without a search.
    private func openRepository(id: String) {
        let placeholder = HFModelSearchResult(
            id: id,
            author: id.split(separator: "/").first.map(String.init),
            description: nil,
            downloads: nil,
            likes: nil,
            lastModified: nil,
            tags: nil,
            privateRepo: nil
        )
        selectedRepo = placeholder
        loadRepoDetails(id)
    }

    private func loadRepoDetails(_ repoId: String) {
        detailsTask?.cancel()
        isLoadingDetails = true
        detailsError = nil
        repoDetails = nil

        let token = LocalKeychainHelper.loadHuggingFaceToken()
        detailsTask = Task { @MainActor in
            do {
                let details = try await HuggingFaceService.fetchModelDetails(repoId: repoId, token: token)
                // The selection may have moved to another repo while this
                // request was in flight; never show the previous model's files.
                guard !Task.isCancelled, self.selectedRepo?.id == repoId else { return }
                self.repoDetails = details
                self.isLoadingDetails = false
            } catch {
                guard !Task.isCancelled, self.selectedRepo?.id == repoId else { return }
                self.detailsError = Self.message(for: error)
                self.isLoadingDetails = false
            }
        }
    }

    /// Starts one job for the model. A split model is requested as a whole set:
    /// downloading a single shard produces a model the engine can never load, so
    /// the manager refuses it and the UI never offers that path.
    private func startDownload(_ file: HFGGUFFile, repoId: String) {
        let token = LocalKeychainHelper.loadHuggingFaceToken()
        let available = repoDetails?.ggufFiles ?? [file]
        let group = HuggingFaceService.splitGroup(for: file, in: available)
        let requests = group.map {
            HFDownloadRequest(
                rfilename: $0.rfilename,
                downloadURL: $0.downloadURL,
                size: $0.size,
                sha256: $0.sha256
            )
        }
        do {
            try downloads.startDownload(
                repoId: repoId,
                files: requests.isEmpty ? [HFDownloadRequest(
                    rfilename: file.rfilename,
                    downloadURL: file.downloadURL,
                    size: file.size,
                    sha256: file.sha256
                )] : requests,
                token: token
            )
        } catch {
            self.detailsError = Self.message(for: error)
        }
    }
}
