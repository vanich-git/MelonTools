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
    @ObservedObject private var downloads = LocalDownloadManager.shared
    var isActive: Bool = true
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @State private var sortOrder: HuggingFaceService.SortOrder = .trendingScore
    @State private var searchResults: [HFModelSearchResult] = []
    @State private var selectedRepo: HFModelSearchResult?
    @State private var repoDetails: HFModelDetails?
    @State private var searchError: String?
    @State private var detailsError: String?
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var isLoadingDetails = false
    @State private var hasMore = true
    @State private var nextOffset = 0
    @State private var searchGeneration = 0
    @State private var activeRequest: HFSearchRequest?
    @State private var searchTask: Task<Void, Never>?
    @State private var detailsTask: Task<Void, Never>?
    @State private var showTokenSheet = false
    @State private var hfToken = LocalKeychainHelper.loadHuggingFaceToken() ?? ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                searchBar
                HStack {
                    Text(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sortOrder == .trendingScore ? L("Trending on Hugging Face") : L("Hugging Face results"))
                        .font(MTTheme.body(10)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Picker(L("Sort by"), selection: $sortOrder) {
                        ForEach([HuggingFaceService.SortOrder.trendingScore, .likes, .downloads, .lastModified]) { order in
                            Text(L(order.title)).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .controlSize(.small)
                    .help(L("Recommended uses Hugging Face trending, not staff picks."))
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
                if let searchError {
                    HStack(alignment: .top, spacing: 6) {
                        Label(searchError, systemImage: "exclamationmark.triangle")
                        Spacer(minLength: 0)
                        Button(L("Retry")) { performSearch() }
                    }
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.danger)
                    .padding(10)
                    .background(MTTheme.danger.opacity(0.08))
                }
                if searchResults.isEmpty {
                    if isSearching {
                        ProgressView(L("Loading..."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if searchError == nil {
                        ContentUnavailableView(L("No models found. Try another query."), systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Spacer()
                    }
                } else {
                    List(searchResults, selection: $selectedRepo) { repo in
                        HFRepositoryRow(repo: repo).tag(repo)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    if hasMore {
                        Button(action: loadMore) {
                            HStack(spacing: 6) {
                                if isLoadingMore { ProgressView().controlSize(.mini) }
                                Text(isLoadingMore ? L("Loading...") : L("Load more"))
                            }
                            .font(MTTheme.body(11))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MTTheme.cyan)
                        .disabled(isLoadingMore || isSearching)
                    }
                }
            }
            .frame(minWidth: 285, idealWidth: 320, maxWidth: 420)
            Group {
                if let repo = selectedRepo {
                    HFModelDetailView(repo: repo, details: repoDetails, isLoading: isLoadingDetails,
                                      error: detailsError, retry: { loadRepoDetails(repo.id) },
                                      download: { startDownload($0, repoId: repo.id) })
                        .id(repo.id)
                } else {
                    ContentUnavailableView(L("Select a model repository from the list"), systemImage: "sidebar.right")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
        .onChange(of: searchQuery) { _, _ in performSearch(debounce: true) }
        .onChange(of: sortOrder) { _, _ in performSearch() }
        .onChange(of: selectedRepo) { _, repo in
            if let repo { loadRepoDetails(repo.id) }
            else { clearDetails() }
        }
        .onAppear {
            if activeRequest == nil || isSearching { performSearch() }
            else if isLoadingDetails, let selectedRepo { loadRepoDetails(selectedRepo.id) }
        }
        .sheet(isPresented: $showTokenSheet) { tokenSheetView }
        .onDisappear {
            searchTask?.cancel()
            detailsTask?.cancel()
            isLoadingMore = false
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search Hugging Face..."), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { performSearch() }
                    .onExitCommand {
                        if !searchQuery.isEmpty { searchQuery = "" }
                        else { searchFocused = false }
                    }
                if !searchQuery.isEmpty {
                    Button(L("Clear search"), systemImage: "xmark.circle.fill") { searchQuery = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .font(MTTheme.body(12))
            .padding(8)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 7))
            Button(L("Hugging Face API Token"), systemImage: "key") { showTokenSheet = true }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help(L("Hugging Face API Token"))
        }
        .padding(12)
        .background {
            if isActive {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0).accessibilityHidden(true)
            }
        }
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
                .accessibilityLabel(L("Close"))
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

    private func performSearch(debounce: Bool = false) {
        searchTask?.cancel()
        clearDetails()
        searchGeneration += 1
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = HFSearchRequest(query: query, sort: sortOrder, offset: 0, generation: searchGeneration)
        activeRequest = request
        isSearching = true
        isLoadingMore = false
        searchError = nil
        searchResults = []
        selectedRepo = nil
        nextOffset = 0
        hasMore = true
        let token = LocalKeychainHelper.loadHuggingFaceToken()
        searchTask = Task { @MainActor in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(350)) }
                try Task.checkCancellation()
                if let id = HuggingFaceService.repositoryID(from: query) {
                    let repo = HFModelSearchResult(id: id, author: id.split(separator: "/").first.map(String.init),
                        description: nil, downloads: nil, likes: nil, lastModified: nil, tags: nil, privateRepo: nil)
                    guard isCurrent(request) else { return }
                    searchResults = [repo]
                    selectedRepo = repo
                    hasMore = false
                    isSearching = false
                    return
                }
                let page = try await HuggingFaceService.searchModels(query: request.query, sort: request.sort, token: token)
                guard isCurrent(request) else { return }
                var known = Set<String>()
                searchResults = page.filter { known.insert($0.id).inserted }
                nextOffset = page.count
                hasMore = page.count == 30
                isSearching = false
                selectedRepo = searchResults.first
            } catch {
                guard isCurrent(request) else { return }
                searchError = Self.message(for: error)
                isSearching = false
            }
        }
    }

    private func loadMore() {
        guard let active = activeRequest, !isSearching, !isLoadingMore, hasMore else { return }
        let request = HFSearchRequest(query: active.query, sort: active.sort, offset: nextOffset, generation: active.generation)
        isLoadingMore = true
        searchError = nil
        let token = LocalKeychainHelper.loadHuggingFaceToken()
        searchTask = Task { @MainActor in
            do {
                let page = try await HuggingFaceService.searchModels(query: request.query, sort: request.sort, offset: request.offset, token: token)
                guard isCurrent(request) else { return }
                var known = Set(searchResults.map(\.id))
                searchResults += page.filter { known.insert($0.id).inserted }
                nextOffset += page.count
                hasMore = page.count == 30
                isLoadingMore = false
            } catch {
                guard isCurrent(request) else { return }
                searchError = Self.message(for: error)
                isLoadingMore = false
            }
        }
    }

    private func isCurrent(_ request: HFSearchRequest) -> Bool {
        !Task.isCancelled && request.belongs(to: activeRequest)
    }

    private static func message(for error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? L("The request failed.") : text
    }

    private func clearDetails() {
        detailsTask?.cancel()
        repoDetails = nil
        detailsError = nil
        isLoadingDetails = false
    }

    private func loadRepoDetails(_ repoId: String) {
        clearDetails()
        isLoadingDetails = true
        let token = LocalKeychainHelper.loadHuggingFaceToken()
        detailsTask = Task { @MainActor in
            do {
                let details = try await HuggingFaceService.fetchModelDetails(repoId: repoId, token: token)
                guard !Task.isCancelled, selectedRepo?.id == repoId else { return }
                repoDetails = details
                isLoadingDetails = false
            } catch {
                guard !Task.isCancelled, selectedRepo?.id == repoId else { return }
                detailsError = Self.message(for: error)
                isLoadingDetails = false
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
