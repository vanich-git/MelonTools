import SwiftUI
import AppKit

struct LocalRuntimeView: View {
    @ObservedObject var runtime = LocalInferenceService.shared
    @ObservedObject var hardware = LocalHardwareService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Follow the newest line while the engine streams. Cleared by scrolling up:
    /// reading history must not be interrupted by incoming output.
    @State private var followTail = true
    @State private var isNearBottom = true
    @State private var contentBottom: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    /// The Console renders only the tail of the ring buffer. Together with the
    /// capped pane this keeps the window from growing with the log.
    private static let visibleLineLimit = 500

    private func metricTile(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title)
                    .font(MTTheme.body(9.5, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(MTTheme.textTertiary)
            Text(value)
                .font(MTTheme.body(13, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(.horizontal, MTTheme.s3)
        .padding(.vertical, MTTheme.s2)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status and hardware card
            VStack(spacing: MTTheme.s3) {
                HStack(alignment: .top, spacing: MTTheme.s4) {
                    // Status box
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Engine Status"))
                            .font(MTTheme.body(11))
                            .foregroundStyle(MTTheme.textSecondary)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(statusText)
                                .font(MTTheme.body(13, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                        }

                        if case .running(let port, _) = runtime.status {
                            Text("127.0.0.1:\(port)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MTTheme.emerald)
                        }
                    }

                    Divider().frame(height: 45).background(Color.primary.opacity(0.08))

                    // Active model box
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Active Model"))
                            .font(MTTheme.body(11))
                            .foregroundStyle(MTTheme.textSecondary)

                        if let model = runtime.currentModel {
                            Text(model.displayName)
                                .font(MTTheme.body(13, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                                .lineLimit(1)
                        } else {
                            Text(L("None loaded"))
                                .font(MTTheme.body(13))
                                .foregroundStyle(MTTheme.textTertiary)
                        }
                    }

                    Spacer()

                    // Hardware summary
                    let hw = hardware.hardwareInfo
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.caption)
                            Text(String(format: L("%@ (%d cores)"), hw.cpuModel, hw.cpuCores))
                                .font(MTTheme.body(11, weight: .medium))
                        }
                        .foregroundStyle(MTTheme.textSecondary)

                        HStack(spacing: 4) {
                            Image(systemName: "memorychip")
                                .font(.caption)
                            let gpuMemory = hw.gpuRecommendedMaxWorkingSetSize ?? 0
                            Text(gpuMemory > 0
                                 ? String(format: L("RAM %@ · GPU %@"),
                                          LocalHardwareService.formatBytes(hw.totalRAM),
                                          LocalHardwareService.formatBytes(gpuMemory))
                                 : String(format: L("RAM %@"),
                                          LocalHardwareService.formatBytes(hw.totalRAM)))
                                .font(MTTheme.body(10.5))
                        }
                        .foregroundStyle(MTTheme.textTertiary)

                        if let driver = hw.gpuDriver {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu.fill")
                                    .font(.caption)
                                Text(driver)
                                    .font(MTTheme.body(10.5))
                            }
                            .foregroundStyle(MTTheme.textTertiary)
                        }
                    }

                    // Runtime controls
                    if runtime.status.isRunning || isStarting {
                        Button(action: { Task { await runtime.stop() } }) {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                Text(L("Stop Engine"))
                            }
                            .font(MTTheme.body(11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(MTTheme.s4)
                .background(Color.primary.opacity(0.02))
            }

            // Live inference figures from the engine itself (§21). They stay
            // hidden until the engine reports readiness.
            if let metrics = runtime.metrics {
                HStack(spacing: MTTheme.s4) {
                    metricTile(
                        title: L("Generation"),
                        value: String(format: "%.1f tok/s", metrics.predictedPerSecond),
                        icon: "bolt.fill",
                        tint: MTTheme.emerald
                    )
                    metricTile(
                        title: L("Prompt"),
                        value: String(format: "%.1f tok/s", metrics.promptPerSecond),
                        icon: "text.alignleft",
                        tint: MTTheme.cyan
                    )
                    metricTile(
                        title: L("Generated tokens"),
                        value: "\(metrics.predictedTokens)",
                        icon: "number",
                        tint: MTTheme.violet
                    )
                    metricTile(
                        title: L("Prompt tokens"),
                        value: "\(metrics.promptTokens)",
                        icon: "doc.text",
                        tint: MTTheme.amber
                    )
                    Spacer()
                }
                .padding(.horizontal, MTTheme.s4)
                .padding(.bottom, MTTheme.s4)
            }

            if let metricsError = runtime.metricsError {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text(metricsError)
                        .font(MTTheme.body(10.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(MTTheme.textTertiary)
                .padding(.horizontal, MTTheme.s4)
                .padding(.bottom, MTTheme.s3)
            }

            Divider().background(Color.primary.opacity(0.06))

            // Logs header
            HStack(spacing: MTTheme.s3) {
                Image(systemName: "terminal")
                    .foregroundStyle(MTTheme.textSecondary)
                Text(L("llama-server Console Output"))
                    .font(MTTheme.body(12, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)

                Spacer()

                Button {
                    followTail.toggle()
                } label: {
                    Image(systemName: followTail ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                }
                .buttonStyle(.plain)
                .foregroundStyle(followTail ? MTTheme.cyan : MTTheme.textTertiary)
                .help(followTail ? L("Pause auto-scroll") : L("Resume auto-scroll"))
                .accessibilityLabel(followTail ? L("Pause auto-scroll") : L("Resume auto-scroll"))

                Button(action: {
                    let full = runtime.logLines.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(full, forType: .string)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text(L("Copy Logs"))
                    }
                    .font(MTTheme.body(10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MTTheme.cyan)
                .opacity(runtime.logLines.isEmpty ? 0.4 : 1)
                .disabled(runtime.logLines.isEmpty)

                Button(action: { runtime.clearLogs() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text(L("Clear"))
                    }
                    .font(MTTheme.body(10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MTTheme.textTertiary)
                .opacity(runtime.logLines.isEmpty ? 0.4 : 1)
                .disabled(runtime.logLines.isEmpty)
            }
            .padding(.horizontal, MTTheme.s4)
            .padding(.vertical, MTTheme.s2 + 2)
            .background(Color.primary.opacity(0.01))

            Divider().background(Color.primary.opacity(0.06))

            // Logs viewer
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if visibleLogRows.isEmpty {
                            Text(L("No server output yet. Launch a model to start inference engine."))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(MTTheme.textTertiary)
                                .padding(MTTheme.s3)
                        } else {
                            ForEach(visibleLogRows) { row in
                                Text(row.text)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(logLineColor(row.text))
                                    .textSelection(.enabled)
                                    .id(row.id)
                            }
                        }
                    }
                    .padding(MTTheme.s3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(logBottomProbe)
                }
                .coordinateSpace(name: "runtimeLogScroll")
                .background(MTTheme.cardSoft)
                .background(logViewportProbe)
                .onPreferenceChange(MTRuntimeLogBottomKey.self) { bottom in
                    contentBottom = bottom
                    updateNearBottom()
                }
                .onPreferenceChange(MTRuntimeLogViewportKey.self) { height in
                    viewportHeight = height
                    updateNearBottom()
                }
                .onChange(of: runtime.logRevision) { _, _ in
                    guard followTail, isNearBottom else { return }
                    scrollToLatest(proxy)
                }
                .onChange(of: viewportHeight) { _, _ in
                    guard followTail, isNearBottom else { return }
                    scrollToLatest(proxy)
                }
                .onAppear {
                    DispatchQueue.main.async { scrollToLatest(proxy) }
                }
            }
            // Fill the space the window offers and never ask for more: the pane
            // is bounded by the window, not by the number of log lines.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var isStarting: Bool {
        if case .starting = runtime.status { return true }
        return false
    }

    private var statusColor: Color {
        switch runtime.status {
        case .running: return MTTheme.emerald
        case .starting: return MTTheme.cyan
        case .stopping: return MTTheme.amber
        case .stopped: return MTTheme.textTertiary
        case .failed: return MTTheme.danger
        }
    }

    private var statusText: String {
        switch runtime.status {
        case .running: return L("Ready (Inference Active)")
        case .starting: return L("Starting Engine...")
        case .stopping: return L("Stopping Engine...")
        case .stopped: return L("Engine Stopped")
        case .failed(let err): return "\(L("Engine Error")): \(err)"
        }
    }

    private func logLineColor(_ line: String) -> Color {
        if line.contains("error") || line.contains("failed") || line.contains("ERR") {
            return MTTheme.danger
        }
        if line.contains("warning") || line.contains("WARN") {
            return MTTheme.gold
        }
        if line.contains("HTTP") || line.contains("listening") || line.contains("model loaded") {
            return MTTheme.emerald
        }
        return MTTheme.textPrimary
    }

    // MARK: - Log tail

    /// One rendered console row. `id` is the line's absolute position in the
    /// ring buffer, so trimming older lines keeps the rows that are still on
    /// screen numbered as before instead of renumbering the whole slice.
    private struct LogRow: Identifiable {
        let id: Int
        let text: String
    }

    private var visibleLogRows: [LogRow] {
        let total = runtime.logLines.count
        let start = max(0, total - Self.visibleLineLimit)
        return (start..<total).map { LogRow(id: $0, text: runtime.logLines[$0]) }
    }

    /// Reports where the end of the content sits inside the scroll viewport.
    private var logBottomProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: MTRuntimeLogBottomKey.self,
                value: geometry.frame(in: .named("runtimeLogScroll")).maxY
            )
        }
    }

    private var logViewportProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: MTRuntimeLogViewportKey.self, value: geometry.size.height)
        }
    }

    /// Follow the tail only when the reader is at the bottom; scrolling up while
    /// the engine streams must not yank the view back.
    private func updateNearBottom() {
        guard viewportHeight > 0 else { return }
        isNearBottom = contentBottom <= viewportHeight + 40
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let lastId = visibleLogRows.last?.id else { return }
        if reduceMotion {
            proxy.scrollTo(lastId, anchor: .bottom)
        } else {
            withAnimation(.linear(duration: 0.1)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }
}

// MARK: - Scroll preferences

private struct MTRuntimeLogBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MTRuntimeLogViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
