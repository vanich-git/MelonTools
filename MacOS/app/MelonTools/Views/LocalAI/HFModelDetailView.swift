import SwiftUI

struct HFModelDetailView: View {
    let repo: HFModelSearchResult
    let details: HFModelDetails?
    let isLoading: Bool
    let error: String?
    let retry: () -> Void
    let download: (HFGGUFFile) -> Void
    @ObservedObject private var downloads = LocalDownloadManager.shared
    @ObservedObject private var store = LocalModelStore.shared
    @State private var selectedVariantID: String?
    @State private var onlyFitting = false
    @State private var readme: String?
    @State private var readmeError: String?
    @State private var readmeAttempt = 0

    private var variants: [HFDownloadVariant] { HFDownloadVariant.variants(from: details?.ggufFiles ?? []) }
    private var visibleVariants: [HFDownloadVariant] { onlyFitting ? variants.filter(\.fitsEstimatedMemory) : variants }
    private var selected: HFDownloadVariant? { visibleVariants.first { $0.id == selectedVariantID } }
    private var recommended: HFDownloadVariant? { HFDownloadVariant.recommended(in: variants) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if isLoading {
                    ProgressView(L("Fetching GGUF files and hardware estimation..."))
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                }
                if let error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(MTTheme.danger)
                        Spacer()
                        Button(L("Retry"), action: retry)
                    }
                    .font(MTTheme.body(12))
                }
                if let details {
                    downloadOptions
                    if !details.description.isEmpty || details.architecture != nil || details.parameterCount != nil || details.license != nil || !details.capabilities.isEmpty {
                        metadata(details)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("README").font(MTTheme.body(12, weight: .semibold))
                    if let readmeError {
                        HStack {
                            Label(readmeError, systemImage: "exclamationmark.triangle")
                            Spacer()
                            Button(L("Retry")) { readmeAttempt += 1 }
                        }
                        .foregroundStyle(MTTheme.danger)
                    } else if let readme {
                        if readme.isEmpty {
                            Text(L("No README published in this repository."))
                                .foregroundStyle(.secondary)
                        } else {
                            HFReadmeView(text: readme)
                                .padding(14)
                                .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 9))
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(MTTheme.body(12))
            }
            .padding(24)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: details) { _, _ in chooseDefault() }
        .onChange(of: onlyFitting) { _, _ in chooseDefault() }
        .onAppear(perform: chooseDefault)
        .task(id: readmeAttempt) { await loadReadme() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HFRepositoryAvatar(owner: details?.author ?? repo.author ?? String(repo.id.split(separator: "/").first ?? ""), size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.displayName).font(MTTheme.body(17, weight: .semibold)).textSelection(.enabled)
                    Text(repo.id).font(MTTheme.body(11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                if let count = details?.downloads ?? repo.downloads {
                    Label(count.formatted(.number.notation(.compactName)), systemImage: "arrow.down")
                        .help(L("Downloads"))
                }
                if let count = details?.likes ?? repo.likes {
                    Label(count.formatted(.number.notation(.compactName)), systemImage: "star")
                        .help(L("Likes"))
                }
                if let updated = HFRepositoryRow.date(details?.lastModified ?? repo.lastModified) {
                    Text(L("Updated") + " " + updated.formatted(date: .abbreviated, time: .omitted))
                }
                if repo.privateRepo == true || repo.gated == true { Label(L("Gated"), systemImage: "lock.fill") }
                Spacer(minLength: 0)
                if let url = URL(string: "https://huggingface.co/\(repo.id)") {
                    Link(destination: url) { Label(L("Open on HF"), systemImage: "arrow.up.right.square") }
                        .buttonStyle(.bordered)
                }
            }
            .font(MTTheme.body(10.5))
            .foregroundStyle(.secondary)
        }
    }

    private var downloadOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L("Download Options")).font(MTTheme.body(12, weight: .semibold))
                Spacer()
                Text(L("This device")).font(MTTheme.body(10.5)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                if variants.isEmpty {
                    Text(L("No GGUF files found in this repository.")).foregroundStyle(.secondary)
                } else {
                    Toggle(L("Only variants estimated to fit this device"), isOn: $onlyFitting)
                        .toggleStyle(.checkbox)
                        .font(MTTheme.body(10.5))
                    if visibleVariants.isEmpty {
                        Text(L("No variants fit the current memory estimate."))
                            .foregroundStyle(.secondary)
                    } else {
                        Menu {
                            ForEach(visibleVariants) { variant in
                                Button {
                                    selectedVariantID = variant.id
                                } label: {
                                    Label(optionTitle(variant), systemImage: variant.id == selectedVariantID ? "checkmark" : "circle")
                                }
                                .disabled(!variant.isComplete)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text("GGUF").font(MTTheme.body(9, weight: .medium)).foregroundStyle(.secondary)
                                if let selected {
                                    Text(selected.file.quantization).font(MTTheme.body(11, weight: .semibold))
                                    Text(selected.hasKnownSize ? LocalHardwareService.formatBytes(selected.size) : L("Size unknown"))
                                        .foregroundStyle(.secondary)
                                    if selected.id == recommended?.id {
                                        Text(L("Recommended"))
                                            .font(MTTheme.body(9))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 4))
                                    }
                                } else {
                                    Text(L("Select a variant"))
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                            }
                            .font(MTTheme.body(11))
                            .padding(9)
                            .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)) }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .accessibilityLabel(L("Select a variant"))
                    }
                    if let selected {
                        Text(selected.name).font(MTTheme.body(10)).foregroundStyle(.secondary).textSelection(.enabled)
                        if !selected.isComplete {
                            Label(L("Incomplete split model — download unavailable"), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(MTTheme.danger)
                        } else if selected.hasKnownSize {
                            Label(L(selected.file.estimation.recommendation.rawValue), systemImage: selected.fitsEstimatedMemory ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(selected.fitsEstimatedMemory ? MTTheme.emerald : MTTheme.amber)
                            Text(L("Estimated memory") + ": " + LocalHardwareService.formatBytes(selected.file.estimation.totalLow) + "–" + LocalHardwareService.formatBytes(selected.file.estimation.totalHigh))
                                .foregroundStyle(.secondary)
                        } else {
                            Label(L("Unknown compatibility"), systemImage: "questionmark.circle").foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(L("Memory estimate, not a compatibility guarantee. Actual use depends on context and runtime support."))
                                .font(MTTheme.body(10)).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            downloadButton(selected)
                        }
                    }
                }
            }
            .font(MTTheme.body(11))
            .padding(12)
            .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 9))
        }
    }

    private func metadata(_ details: HFModelDetails) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("Details")).font(MTTheme.body(12, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                if !details.description.isEmpty { Text(details.description).textSelection(.enabled) }
                if let count = details.parameterCount { LabeledContent(L("Parameters"), value: count.formatted(.number.notation(.compactName))) }
                if let architecture = details.architecture { LabeledContent(L("Architecture"), value: architecture) }
                if let license = details.license { LabeledContent(L("License"), value: license) }
                if !details.capabilities.isEmpty { LabeledContent(L("Capabilities"), value: details.capabilities.joined(separator: ", ")) }
            }
            .font(MTTheme.body(11))
            .padding(12)
            .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 9))
        }
    }

    @ViewBuilder private func downloadButton(_ variant: HFDownloadVariant) -> some View {
        if isInstalled(variant) {
            Label(L("Installed"), systemImage: "checkmark.circle.fill").foregroundStyle(MTTheme.emerald)
        } else if isDownloading(variant) {
            Label(L("Downloading..."), systemImage: "arrow.down.circle").foregroundStyle(MTTheme.cyan)
        } else {
            Button { download(variant.file) } label: {
                Label(L("Download") + (variant.hasKnownSize ? " " + LocalHardwareService.formatBytes(variant.size) : ""), systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(!variant.isComplete)
        }
    }

    private func chooseDefault() {
        if !visibleVariants.contains(where: { $0.id == selectedVariantID }) {
            selectedVariantID = HFDownloadVariant.defaultSelection(in: visibleVariants)?.id
        }
    }

    private func optionTitle(_ variant: HFDownloadVariant) -> String {
        var title = variant.file.quantization + " · " + variant.name
        title += " · " + (variant.hasKnownSize ? LocalHardwareService.formatBytes(variant.size) : L("Size unknown"))
        if variant.id == recommended?.id { title += " · " + L("Recommended") }
        if !variant.isComplete { title += " · " + L("Incomplete split model") }
        else if variant.hasKnownSize { title += " · " + L(variant.file.estimation.recommendation.rawValue) }
        return title
    }

    private func isDownloading(_ variant: HFDownloadVariant) -> Bool {
        downloads.items.contains { item in
            item.repoId == repo.id && variant.files.contains { $0.rfilename == item.rfilename }
                && (item.state == .downloading || item.state == .queued || item.state == .paused)
        }
    }

    private func isInstalled(_ variant: HFDownloadVariant) -> Bool {
        store.models.contains { model in
            model.repoId == repo.id && variant.files.allSatisfy { file in
                model.files.contains { ($0 as NSString).lastPathComponent == (file.rfilename as NSString).lastPathComponent }
            }
        }
    }

    private func loadReadme() async {
        readmeError = nil
        do {
            let text = try await HuggingFaceService.fetchReadme(repoId: repo.id, token: LocalKeychainHelper.loadHuggingFaceToken())
            guard !Task.isCancelled else { return }
            readme = text
        } catch {
            guard !Task.isCancelled else { return }
            readmeError = error.localizedDescription
        }
    }
}
