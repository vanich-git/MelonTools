import AppKit
import SwiftUI

/// Codex API: local OpenAI-compatible gateway on the account pool (CLIProxyAPI sidecar).
struct CodexAPIView: View {
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var store = CodexStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "codex api",
                    title: L("API Service"),
                    subtitle: L("API subtitle")
                )

                CodexControlCard()
                usageCard
                configCard
                endpointsCard
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.api")
        }
        .background(MTTheme.background)
        .onAppear {
            store.load()
            Task { await gateway.healthCheck() }
        }
    }

    private var usageCard: some View {
        MTCard(title: L("Usage"), systemImage: "chart.bar.fill", accent: MTTheme.emerald, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if let last = gateway.lastUsage {
                    VStack(alignment: .leading, spacing: MTTheme.s2) {
                        HStack(spacing: MTTheme.s4) {
                            usageItem(label: L("Model"), value: last.model)
                            usageItem(label: L("Provider / Account"), value: "\(last.provider) / \(last.auth)")
                        }
                        HStack(spacing: MTTheme.s4) {
                            usageItem(label: L("Date & Time"), value: Self.dateFormatter.string(from: last.time))
                            usageItem(label: L("Mode"), value: last.mode)
                            usageStatusItem(status: last.status)
                        }
                        HStack(spacing: MTTheme.s4) {
                            usageItem(label: L("INPUT"), value: "\(last.inputTokens)")
                            usageItem(label: L("OUTPUT"), value: "\(last.outputTokens)")
                        }
                    }

                    if gateway.usageHistory.count > 1 {
                        Rectangle()
                            .fill(MTTheme.borderColor.opacity(0.6))
                            .frame(height: 1)

                        Text(L("Recent Usage"))
                            .font(MTTheme.body(11, weight: .semibold))
                            .foregroundStyle(MTTheme.textSecondary)

                        VStack(spacing: MTTheme.s1) {
                            ForEach(gateway.usageHistory.prefix(5)) { item in
                                HStack(spacing: MTTheme.s2) {
                                    Text(Self.timeFormatter.string(from: item.time))
                                        .font(MTTheme.mono(10))
                                        .foregroundStyle(MTTheme.textTertiary)
                                        .frame(width: 55, alignment: .leading)
                                    Text(item.model)
                                        .font(MTTheme.mono(10))
                                        .foregroundStyle(MTTheme.textPrimary)
                                        .lineLimit(1)
                                    Text("\(item.provider)/\(item.auth)")
                                        .font(MTTheme.mono(9))
                                        .foregroundStyle(MTTheme.textSecondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("in: \(item.inputTokens)")
                                        .font(MTTheme.mono(9))
                                        .foregroundStyle(MTTheme.textSecondary)
                                    Text("out: \(item.outputTokens)")
                                        .font(MTTheme.mono(9))
                                        .foregroundStyle(MTTheme.textSecondary)
                                    statusBadge(item.status)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                } else {
                    Text(L("No usage data yet"))
                        .font(MTTheme.mono(11))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
    }

    private func usageItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
            Text(value)
                .font(MTTheme.mono(11, weight: .medium))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(minWidth: 100, alignment: .leading)
    }

    private func usageStatusItem(status: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Status"))
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
            statusBadge(status)
        }
        .frame(minWidth: 80, alignment: .leading)
    }

    private func statusBadge(_ status: Int) -> some View {
        let isOk = (200...299).contains(status)
        return Text("\(status)")
            .font(MTTheme.mono(10, weight: .semibold))
            .foregroundStyle(isOk ? MTTheme.emerald : MTTheme.danger)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((isOk ? MTTheme.emerald : MTTheme.danger).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        return df
    }()

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    private var configCard: some View {
        MTCard(title: L("Configuration"), systemImage: "gear", accent: MTTheme.cyan, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                HStack(spacing: MTTheme.s3) {
                    Text(L("api key"))
                        .font(MTTheme.mono(11))
                        .foregroundStyle(MTTheme.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    Text(gateway.apiKey)
                        .font(MTTheme.mono(11))
                        .foregroundStyle(MTTheme.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MTGlassButton(title: L("Copy"), size: .small, tint: MTTheme.cyan) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(gateway.apiKey, forType: .string)
                    }
                    MTGlassButton(title: L("Rotate"), size: .small, tint: MTTheme.amber) {
                        gateway.rotateAPIKey()
                    }
                }
                Text(L("Use this key as the OpenAI API key in other tools. Rotating it updates the gateway and the Codex route; restart the service only if another client still uses the old key."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private var endpointsCard: some View {
        MTCard(title: L("Client setup"), systemImage: "doc.text", accent: MTTheme.violet, isBento: true) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                snippet(L("Base URL"), gateway.baseURL, copy: true)
                snippet(L("API key"), gateway.apiKey)
                Text(L("Any OpenAI-compatible tool can point at this service. Requests are served from the signed-in Codex accounts and are billed to your ChatGPT subscriptions."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private func snippet(_ label: String, _ value: String, copy: Bool = false) -> some View {
        HStack(spacing: MTTheme.s3) {
            Text(label)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(MTTheme.mono(11))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
            if copy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L("Copy"))
            }
            Spacer()
        }
    }

}
