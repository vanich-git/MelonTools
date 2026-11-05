import SwiftUI

/// Browser for official llama.cpp releases, in the spirit of LM Studio's
/// runtime manager: pick a build, the app downloads and verifies both macOS
/// slices, merges them and installs the result as a normal runtime package.
struct RuntimeCatalogSheet: View {
    @ObservedObject var runtimeStore: RuntimeStore
    @StateObject private var catalog = RuntimeCatalogService()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: MTTheme.s3) {
            HStack(spacing: MTTheme.s2) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(MTTheme.emerald)
                Text(L("Available Runtimes"))
                    .font(MTTheme.body(14, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                Spacer()
                Button {
                    Task { await catalog.load(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L("Refresh"))
                .accessibilityLabel(L("Refresh"))
                .disabled(catalog.isLoading)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
                .keyboardShortcut(.cancelAction)
            }

            Text(L("Official llama.cpp builds. Melon Tools downloads both macOS architecture slices, verifies their SHA-256 from the GitHub release metadata and merges them into one universal engine."))
                .font(MTTheme.body(11))
                .foregroundStyle(MTTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            content

            if runtimeStore.isInstalling {
                VStack(alignment: .leading, spacing: 4) {
                    if runtimeStore.installTotal > 0 {
                        ProgressView(
                            value: Double(runtimeStore.installBytes),
                            total: Double(runtimeStore.installTotal)
                        )
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(runtimeStore.installStage)
                        .font(MTTheme.body(10.5))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
            if let error = runtimeStore.installError {
                Text(error)
                    .font(MTTheme.body(10.5))
                    .foregroundStyle(MTTheme.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = catalog.error {
                Text(error)
                    .font(MTTheme.body(10.5))
                    .foregroundStyle(MTTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L("Only official releases that contain both macOS slices and SHA-256 metadata are listed. The engine is never started during installation."))
                .font(MTTheme.body(9.5))
                .foregroundStyle(MTTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MTTheme.s4)
        .frame(
            minWidth: 560, idealWidth: 640, maxWidth: 760,
            minHeight: 400, idealHeight: 500, maxHeight: 700
        )
        .background(MTTheme.background)
        .task { await catalog.load() }
    }

    @ViewBuilder
    private var content: some View {
        if catalog.releases.isEmpty {
            VStack(spacing: MTTheme.s2) {
                if catalog.isLoading {
                    ProgressView()
                } else {
                    Text(L("No downloadable runtimes."))
                        .font(MTTheme.body(12))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(catalog.releases) { release in
                        releaseRow(release)
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func releaseRow(_ release: RuntimeCatalogRelease) -> some View {
        let installed = runtimeStore.runtimes.contains { $0.build == release.tag }
        let installing = runtimeStore.isInstalling
            && runtimeStore.installingReleaseTag == release.tag
        return HStack(spacing: MTTheme.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(release.tag)
                    .font(MTTheme.mono(12.5, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                HStack(spacing: 6) {
                    if let date = release.publishedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                    }
                    Text("macOS universal · \(LocalHardwareService.formatBytes(UInt64(max(0, release.totalBytes))))")
                }
                .font(MTTheme.body(10))
                .foregroundStyle(MTTheme.textTertiary)
            }
            Spacer(minLength: MTTheme.s3)
            if installed {
                Text(L("Installed"))
                    .font(MTTheme.body(10, weight: .semibold))
                    .foregroundStyle(MTTheme.emerald)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(MTTheme.emerald.opacity(0.12), in: Capsule())
            } else if installing {
                ProgressView().controlSize(.small)
                Button(L("Cancel")) { runtimeStore.cancelInstall() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(L("Install")) {
                    runtimeStore.install(catalog: release)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(runtimeStore.isInstalling)
            }
        }
        .padding(.vertical, 9)
    }
}
