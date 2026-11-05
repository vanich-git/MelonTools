import SwiftUI

struct LocalDownloadsView: View {
    @ObservedObject var manager = LocalDownloadManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Top action bar
            HStack(spacing: MTTheme.s3) {
                Text(L("Active & Completed Downloads"))
                    .font(MTTheme.body(13, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)

                Spacer()

                if !manager.items.isEmpty {
                    Button(L("Clear Finished")) {
                        manager.clearFinished()
                    }
                    .buttonStyle(.plain)
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textTertiary)
                }
            }
            .padding(.horizontal, MTTheme.s4)
            .padding(.vertical, MTTheme.s3)
            .background(Color.primary.opacity(0.02))

            Divider().background(Color.primary.opacity(0.06))

            if manager.items.isEmpty {
                VStack(spacing: MTTheme.s3) {
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(MTTheme.textTertiary)
                    Text(L("No downloads in progress"))
                        .font(MTTheme.body(14, weight: .medium))
                        .foregroundStyle(MTTheme.textSecondary)
                    Text(L("Models you download from Hugging Face will appear here."))
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: MTTheme.s3) {
                        ForEach(manager.items) { item in
                            downloadCard(item)
                        }
                    }
                    .padding(MTTheme.s4)
                }
            }
        }
    }

    private func downloadCard(_ item: DownloadItem) -> some View {
        MTCard {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.rfilename)
                            .font(MTTheme.body(13, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                            .lineLimit(1)
                            .help(item.rfilename)
                        HStack(spacing: 6) {
                            if !item.repoId.isEmpty {
                                Text(item.repoId)
                                    .font(MTTheme.body(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            // A split model is one download: show which part is in
                            // the row so a five-part set is legible.
                            if let index = item.shardIndex, let total = item.shardTotal {
                                Text(String(format: L("Part %d of %d"), index, total))
                                    .font(MTTheme.body(10, weight: .medium))
                                    .foregroundStyle(MTTheme.textTertiary)
                            }
                        }
                    }

                    Spacer()

                    // Action buttons
                    HStack(spacing: 8) {
                        switch item.state {
                        case .downloading:
                            Button(action: { manager.pauseDownload(id: item.id) }) {
                                Image(systemName: "pause.fill")
                            }
                            .buttonStyle(.bordered)
                            .help(L("Pause Download"))
                            .accessibilityLabel(L("Pause Download"))

                            Button(action: { manager.cancelDownload(id: item.id) }) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .help(L("Cancel Download"))
                            .accessibilityLabel(L("Cancel Download"))

                        case .paused:
                            Button(action: {
                                let token = LocalKeychainHelper.loadHuggingFaceToken()
                                manager.resumeDownload(id: item.id, token: token)
                            }) {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MTTheme.emerald)
                            .help(L("Resume Download"))
                            .accessibilityLabel(L("Resume Download"))

                            Button(action: { manager.cancelDownload(id: item.id) }) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .help(L("Cancel Download"))
                            .accessibilityLabel(L("Cancel Download"))

                        case .failed:
                            Button(action: {
                                let token = LocalKeychainHelper.loadHuggingFaceToken()
                                manager.resumeDownload(id: item.id, token: token)
                            }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(MTTheme.amber)
                            .help(L("Retry Download"))
                            .accessibilityLabel(L("Retry Download"))

                            Button(action: { manager.cancelDownload(id: item.id) }) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .help(L("Remove Download"))
                            .accessibilityLabel(L("Remove Download"))

                        case .completed:
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(MTTheme.emerald)
                                Text(L("Completed"))
                                    .font(MTTheme.body(11, weight: .semibold))
                                    .foregroundStyle(MTTheme.emerald)
                            }

                        case .queued:
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                                Text(L("Queued"))
                                    .font(MTTheme.body(11))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            Button(action: { manager.cancelDownload(id: item.id) }) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.bordered)
                            .help(L("Cancel Download"))
                            .accessibilityLabel(L("Cancel Download"))

                        case .verifying:
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                                Text(L("Verifying GGUF..."))
                                    .font(MTTheme.body(11, weight: .medium))
                                    .foregroundStyle(MTTheme.cyan)
                            }

                        case .cancelled:
                            Text(L("Cancelled"))
                                .font(MTTheme.body(11))
                                .foregroundStyle(MTTheme.textTertiary)
                            Button(action: { manager.removeCompleted(id: item.id) }) {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .help(L("Remove Download"))
                            .accessibilityLabel(L("Remove Download"))
                        }
                    }
                }

                // Progress bar
                if item.hasKnownSize || item.state == .completed {
                    ProgressView(value: item.progress)
                        .tint(progressTint(for: item.state))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(progressTint(for: item.state))
                }

                // Stats row
                HStack {
                    Text(statsText(for: item))
                        .font(MTTheme.body(10.5))
                        .foregroundStyle(MTTheme.textSecondary)

                    Spacer()

                    if item.state == .downloading && !item.formattedSpeed.isEmpty {
                        Text(item.formattedSpeed)
                            .font(MTTheme.body(10.5, weight: .medium))
                            .foregroundStyle(MTTheme.cyan)
                    }

                    if let err = item.errorMessage {
                        Text(err)
                            .font(MTTheme.body(10.5))
                            .foregroundStyle(MTTheme.danger)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// "<n>% (<downloaded> / <total>)" once the total is known, otherwise just
    /// the downloaded amount — printing "0 KB" as a total only confuses.
    private func statsText(for item: DownloadItem) -> String {
        let done = LocalHardwareService.formatBytes(item.downloadedBytes)
        guard item.hasKnownSize else { return done }
        let total = LocalHardwareService.formatBytes(item.totalBytes)
        return "\(item.formattedProgress) (\(done) / \(total))"
    }

    private func progressTint(for state: DownloadTaskState) -> Color {
        switch state {
        case .completed: return MTTheme.emerald
        case .failed: return MTTheme.danger
        case .paused: return MTTheme.amber
        case .verifying: return MTTheme.violet
        case .cancelled: return MTTheme.textTertiary
        default: return MTTheme.cyan
        }
    }
}
