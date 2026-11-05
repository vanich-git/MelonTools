import SwiftUI

// MARK: - Request/response parsing (pure, testable without a window)

/// Structured failure of one local-AI request.
///
/// The transport used to surface `HTTP N` and drop the body, which hid the
/// engine's own reason ("model not found", "context size exceeded"). The body
/// is parsed into a message plus a code and is sanitized before it reaches the
/// screen, because an error body can echo an API key.
struct LocalAIRequestError: Error, Equatable, LocalizedError {
    var status: Int?
    var code: String?
    var message: String

    var errorDescription: String? {
        var parts: [String] = []
        if let status { parts.append("HTTP \(status)") }
        if let code, !code.isEmpty { parts.append(code) }
        if !message.isEmpty { parts.append(message) }
        return parts.joined(separator: " · ")
    }

    /// Reads `{"error": {"message": …, "code": …}}`, `{"error": "…"}` and
    /// `{"message": "…"}`, falling back to a truncated body.
    static func parse(status: Int?, body: String) -> LocalAIRequestError {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var message: String?
        var code: String?
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                message = error["message"] as? String
                code = (error["code"] as? String) ?? (error["type"] as? String)
            } else if let error = json["error"] as? String {
                message = error
            } else if let text = json["message"] as? String {
                message = text
            }
        }
        let fallback = trimmed.isEmpty ? L("empty response body") : String(trimmed.prefix(300))
        return LocalAIRequestError(
            status: status,
            code: code.map { sanitize($0) },
            message: sanitize(message ?? fallback)
        )
    }

    /// Drops credential-shaped tokens from a body or message.
    static func sanitize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let value = String(word)
            return looksSecret(value) ? "<redacted>" : value
        }
        return words.joined(separator: " ")
    }

    /// Long opaque tokens (bearer tokens, API keys, session ids) are secrets in
    /// an error body; ordinary words and short numbers are not.
    static func looksSecret(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard scalars.count >= 24 else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."
        )
        return scalars.allSatisfy { allowed.contains($0) }
    }
}

/// Token counters reported by an OpenAI-compatible endpoint.
struct LocalAIUsage: Equatable {
    var promptTokens: Int? = nil
    var completionTokens: Int? = nil
}

/// llama.cpp's own counters, sent with the final streamed chunk.
struct LocalAITimings: Equatable {
    var promptN: Int? = nil
    var predictedN: Int? = nil
    var predictedPerSecond: Double? = nil
}

/// One SSE `data:` payload of a chat-completions stream.
struct LocalAIStreamChunk: Equatable {
    var content = ""
    var reasoning = ""
    var finishReason: String? = nil
    var usage: LocalAIUsage? = nil
    var timings: LocalAITimings? = nil
    var done = false

    static func parse(line: String) -> LocalAIStreamChunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            var chunk = LocalAIStreamChunk()
            chunk.done = true
            return chunk
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var chunk = LocalAIStreamChunk()
        if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any] {
                chunk.content = (delta["content"] as? String) ?? ""
                // Reasoning models stream the scratchpad separately.
                chunk.reasoning = (delta["reasoning_content"] as? String) ?? ""
            }
            chunk.finishReason = choice["finish_reason"] as? String
        }
        if let usage = json["usage"] as? [String: Any] {
            chunk.usage = LocalAIUsage(
                promptTokens: usage["prompt_tokens"] as? Int,
                completionTokens: usage["completion_tokens"] as? Int
            )
        }
        if let timings = json["timings"] as? [String: Any] {
            chunk.timings = LocalAITimings(
                promptN: timings["prompt_n"] as? Int,
                predictedN: timings["predicted_n"] as? Int,
                predictedPerSecond: timings["predicted_per_second"] as? Double
            )
        }
        return chunk
    }
}

/// Counters for one streamed completion.
///
/// SSE chunks are not tokens: a delta can be a single character or a whole
/// word, so the delta count is only an estimate and is marked as one.
struct LocalAIStreamStats: Equatable {
    var usage: LocalAIUsage? = nil
    var timings: LocalAITimings? = nil
    /// Number of chunks that carried visible text.
    var deltaCount = 0

    mutating func note(_ chunk: LocalAIStreamChunk) {
        if chunk.usage != nil { usage = chunk.usage }
        if chunk.timings != nil { timings = chunk.timings }
        if !chunk.content.isEmpty || !chunk.reasoning.isEmpty { deltaCount += 1 }
    }

    var promptTokens: (value: Int, approximate: Bool)? {
        if let tokens = usage?.promptTokens { return (tokens, false) }
        if let tokens = timings?.promptN { return (tokens, false) }
        return nil
    }

    var completionTokens: (value: Int, approximate: Bool)? {
        if let tokens = usage?.completionTokens { return (tokens, false) }
        if let tokens = timings?.predictedN { return (tokens, false) }
        if deltaCount > 0 { return (deltaCount, true) }
        return nil
    }

    var tokensPerSecond: Double? { timings?.predictedPerSecond }
}

/// The answer and the scratchpad, kept apart.
///
/// An earlier version copied the reasoning into the answer box when the model
/// produced no final text, so the same paragraph rendered twice and looked like
/// a real answer. The two fields stay separate; the UI labels the scratchpad.
struct LocalAIResponseText: Equatable {
    var answer = ""
    var reasoning = ""

    var hasAnswer: Bool { !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasReasoning: Bool { !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Gateway E2E checks

/// One sub-check of the public-gateway pass.
struct LocalAIGatewayCheck: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case running
        case passed(String)
        case failed(String)
    }

    let id: String
    let title: String
    var state: State = .pending
}

// MARK: - Sheet

/// Manual smoke test for one local model.
///
/// Two explicit paths. "Engine test" talks to the llama.cpp router on its own
/// loopback port, exactly like the first version did. "Gateway E2E" goes
/// through the public gateway the rest of the app uses (auth, routing, catalog,
/// Chat Completions and Responses), so a model that answers the router but is
/// unreachable through the gateway is caught here instead of in the user's
/// editor.
struct LocalModelTestSheet: View {
    let model: LocalModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var runtime = LocalInferenceService.shared
    @ObservedObject private var gateway = CodexGatewayService.shared

    enum Mode: String, CaseIterable, Identifiable {
        case engine
        case gateway

        var id: String { rawValue }
    }

    private enum Phase: Equatable {
        case idle
        case startingEngine
        case generating
        case finished
        case failed(String)
    }

    @State private var mode: Mode = .engine
    @State private var prompt = "Hello! Please tell me in one short paragraph what you can do."
    /// Full accumulated text; `displayed*` are the coalesced copies the UI
    /// renders (see `MTTextBatcher`).
    @State private var answer = ""
    @State private var reasoning = ""
    @State private var displayedAnswer = ""
    @State private var displayedReasoning = ""
    @State private var answerBatcher = MTTextBatcher()
    @State private var reasoningBatcher = MTTextBatcher()

    @State private var phase: Phase = .idle
    /// Result of the structured tool-call probe (§22). `nil` means not run.
    @State private var toolProbe: ToolProbeResult?
    @State private var isProbingTool = false
    @State private var stats = LocalAIStreamStats()
    @State private var elapsed: TimeInterval = 0

    /// One owner for the running test, the tool probe and the gateway pass:
    /// Stop and `onDisappear` cancel exactly one task.
    @State private var activeTask: Task<Void, Never>?
    @State private var ticker: Task<Void, Never>?

    @State private var gatewayChecks: [LocalAIGatewayCheck] = []
    @State private var isRunningGateway = false

    /// Auto-follow only while the reader is at the bottom.
    @State private var contentBottom: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var isNearBottom = true

    /// Set when the engine stopped on `finish_reason: "length"`, i.e. the model
    /// ran out of budget — normal for reasoning models that spend the whole
    /// allowance thinking.
    @State private var truncated = false
    @State private var pendingSwitch = false

    private enum ToolProbeResult: Equatable {
        case success(name: String, arguments: String)
        case failure(String)
    }

    /// Reasoning models burn most of the allowance before they answer, so the
    /// old 512 was almost always consumed by the scratchpad alone.
    private static let maxTokens = 1536

    private static let sheetWidth: CGFloat = 620
    private static let sheetHeight: CGFloat = 620

    /// Sub-checks of the gateway pass, in run order.
    static let gatewayChecklist: [(id: String, title: String)] = [
        ("chat", "Chat · non-stream"),
        ("chatStream", "Chat · stream"),
        ("responses", "Responses · non-stream"),
        ("responsesStream", "Responses · stream"),
        ("tools", "Tools"),
        ("cancel", "Cancel"),
    ]

    private var isBusy: Bool {
        phase == .startingEngine || phase == .generating || isProbingTool || isRunningGateway
    }

    private var hasDisplayedAnswer: Bool {
        !displayedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasDisplayedReasoning: Bool {
        !displayedReasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A reasoning model that never left its scratchpad owes the user an
    /// explanation instead of a duplicated block of text.
    private var showsMissingAnswerNote: Bool {
        phase == .finished && hasDisplayedReasoning && !hasDisplayedAnswer
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.primary.opacity(0.08))

            VStack(alignment: .leading, spacing: MTTheme.s3) {
                modePicker
                if mode == .engine {
                    promptSection
                    engineControls
                } else {
                    gatewayControls
                }
                if case .failed(let message) = phase {
                    errorBanner(message)
                }
                responseSection
            }
            .padding(MTTheme.s4)
        }
        .frame(
            minWidth: 560, idealWidth: Self.sheetWidth, maxWidth: 780,
            minHeight: 480, idealHeight: Self.sheetHeight, maxHeight: 780
        )
        .background(MTTheme.background)
        .onDisappear {
            activeTask?.cancel()
            activeTask = nil
            ticker?.cancel()
            ticker = nil
        }
        .confirmationDialog(
            L("Switch Model?"),
            isPresented: $pendingSwitch,
            titleVisibility: .visible
        ) {
            Button(L("Stop current and test")) {
                Task {
                    await runtime.stop()
                    runTest(forceSwitch: true)
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            if let current = runtime.currentModel {
                Text(String(
                    format: L("%@ is running. Stop it and test %@?"),
                    current.displayName, model.displayName
                ))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: MTTheme.s3) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MTTheme.emerald)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(L("Test Model"))
                    .font(MTTheme.body(14, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                Text("\(model.displayName) · \(model.id)")
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: MTTheme.s2)

            phaseBadge

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MTTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help(L("Close"))
            .accessibilityLabel(L("Close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, MTTheme.s4)
        .padding(.vertical, MTTheme.s3)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch phase {
        case .startingEngine:
            badge(L("Loading engine..."), color: MTTheme.amber, spinning: true)
        case .generating:
            badge(L("Generating..."), color: MTTheme.cyan, spinning: true)
        case .finished:
            badge(L("Done"), color: MTTheme.emerald, spinning: false)
        case .failed:
            badge(L("Failed"), color: MTTheme.danger, spinning: false)
        case .idle:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color, spinning: Bool) -> some View {
        HStack(spacing: 5) {
            if spinning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 11, height: 11)
            }
            Text(text)
                .font(MTTheme.body(10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.13))
        .clipShape(Capsule())
    }

    // MARK: - Mode

    private var modePicker: some View {
        HStack(spacing: MTTheme.s2) {
            MTSegmented(selection: $mode, options: [
                (.engine, L("Engine test")),
                (.gateway, L("Gateway E2E")),
            ], width: 250)
            .disabled(isBusy)
            .help(mode == .engine
                  ? L("Talks to the local engine router directly.")
                  : L("Runs Chat Completions, Responses, tools and cancel through the public gateway."))

            if mode == .gateway {
                Text("127.0.0.1:\(gateway.port)")
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textTertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            Text(L("Prompt:"))
                .font(MTTheme.body(12, weight: .semibold))
                .foregroundStyle(MTTheme.textSecondary)

            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .foregroundStyle(MTTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 82)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MTTheme.cardSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .disabled(isBusy)
        }
    }

    // MARK: - Controls

    private var engineControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: MTTheme.s2) {
                Button { runTest() } label: {
                    HStack(spacing: 6) {
                        if phase == .startingEngine || phase == .generating {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(phase == .startingEngine || phase == .generating
                             ? L("Generating...")
                             : L("Run Test Completion"))
                            .font(MTTheme.body(11.5, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MTTheme.emerald)
                .controlSize(.regular)
                .disabled(isBusy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isBusy {
                    Button(L("Stop")) { cancelRun() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }

                // Structured tool call is a separate protocol check: a model can
                // chat fluently and still fail to emit `tool_calls` (§22).
                Button {
                    runToolProbe()
                } label: {
                    HStack(spacing: 5) {
                        if isProbingTool {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(L("Test tool call"))
                            .font(MTTheme.body(11.5, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isBusy)

                metricsRow

                Spacer(minLength: 0)

                if !isBusy && (!answer.isEmpty || !reasoning.isEmpty) {
                    Button(L("Clear")) { clearRun() }
                        .buttonStyle(.plain)
                        .font(MTTheme.body(11))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }

            if !isBusy, truncated {
                truncationNote
            }

            // The probe result carries a tool name and a JSON argument list,
            // which never fit beside the buttons: it gets a full-width row.
            if let probe = toolProbe {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: probeIcon(probe))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(probeColor(probe))
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(probeTitle(probe))
                            .font(MTTheme.body(11.5, weight: .semibold))
                            .foregroundStyle(probeColor(probe))
                        if case .success(_, let arguments) = probe, !arguments.isEmpty {
                            Text(arguments)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(MTTheme.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(probeColor(probe).opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var gatewayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: MTTheme.s2) {
                Button {
                    runGatewayChecks()
                } label: {
                    HStack(spacing: 6) {
                        if isRunningGateway {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(L("Gateway check"))
                            .font(MTTheme.body(11.5, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MTTheme.cyan)
                .controlSize(.regular)
                .disabled(isBusy)

                if isRunningGateway {
                    Button(L("Stop")) { cancelRun() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }

                if elapsed > 0 {
                    metric(String(format: "%.1f s", elapsed), color: MTTheme.textTertiary)
                }

                Spacer(minLength: 0)
            }

            if gatewayChecks.isEmpty {
                Text(L("Runs Chat Completions, Responses (stream and non-stream), tools and cancel through the gateway the app uses."))
                    .font(MTTheme.body(10.5))
                    .foregroundStyle(MTTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(gatewayChecks) { check in
                        HStack(spacing: 6) {
                            Image(systemName: checkIcon(check.state))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(checkColor(check.state))
                                .frame(width: 12)
                            Text(check.title)
                                .font(MTTheme.body(11))
                                .foregroundStyle(MTTheme.textSecondary)
                            Spacer(minLength: 8)
                            Text(checkDetail(check.state))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(checkColor(check.state))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    private func checkIcon(_ state: LocalAIGatewayCheck.State) -> String {
        switch state {
        case .pending: return "circle.dotted"
        case .running: return "circle.dashed"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func checkColor(_ state: LocalAIGatewayCheck.State) -> Color {
        switch state {
        case .pending: return MTTheme.textTertiary
        case .running: return MTTheme.cyan
        case .passed: return MTTheme.emerald
        case .failed: return MTTheme.danger
        }
    }

    private func checkDetail(_ state: LocalAIGatewayCheck.State) -> String {
        switch state {
        case .pending: return L("pending")
        case .running: return L("running")
        case .passed(let detail): return detail
        case .failed(let message): return message
        }
    }

    /// Prompt and completion counters are reported separately: a combined
    /// "tokens" number hid the prefill cost and made slow models look wrong.
    @ViewBuilder
    private var metricsRow: some View {
        if isBusy || phase == .finished {
            HStack(spacing: 6) {
                if let prompt = stats.promptTokens {
                    metric("\((prompt.approximate ? "≈" : ""))\(prompt.value) prompt", color: MTTheme.textTertiary)
                }
                if let completion = stats.completionTokens {
                    metric("\((completion.approximate ? "≈" : ""))\(completion.value) tok", color: MTTheme.textSecondary)
                }
                if let rate = stats.tokensPerSecond, rate > 0 {
                    metric(String(format: "%.1f tok/s", rate), color: MTTheme.cyan)
                }
                metric(String(format: "%.1f s", elapsed), color: MTTheme.textTertiary)
            }
        }
    }

    private func probeIcon(_ probe: ToolProbeResult) -> String {
        switch probe {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func probeColor(_ probe: ToolProbeResult) -> Color {
        switch probe {
        case .success: return MTTheme.emerald
        case .failure: return MTTheme.danger
        }
    }

    private func probeTitle(_ probe: ToolProbeResult) -> String {
        switch probe {
        case .success(let name, _):
            return L("Tool call received") + ": " + name
        case .failure(let message):
            return message
        }
    }

    private func metric(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
            Text(message)
                .font(MTTheme.body(11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(MTTheme.danger)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MTTheme.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var truncationNote: some View {
        HStack(spacing: 5) {
            Image(systemName: "scissors")
                .font(.system(size: 9, weight: .semibold))
            Text(String(
                format: L("Stopped at the %d token limit. The model may still be reasoning — run it again for a longer answer."),
                Self.maxTokens
            ))
            .font(MTTheme.body(10.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(MTTheme.amber)
    }

    // MARK: - Response

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: MTTheme.s2) {
            HStack(spacing: MTTheme.s2) {
                Text(L("Response:"))
                    .font(MTTheme.body(12, weight: .semibold))
                    .foregroundStyle(MTTheme.textSecondary)
                Spacer()
                if hasDisplayedReasoning {
                    Text(L("Reasoning is shown separately"))
                        .font(MTTheme.body(10))
                        .foregroundStyle(MTTheme.textTertiary)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if hasDisplayedReasoning {
                            reasoningHeader
                            // Reasoning arrives as Markdown too; showing it raw
                            // left `###` and `**` in the scratchpad.
                            MarkdownText(
                                text: displayedReasoning,
                                baseSize: 11.5,
                                tint: MTTheme.textTertiary
                            )
                            .textSelection(.enabled)
                        }
                        if hasDisplayedAnswer {
                            // No outer .font: it would flatten the heading and
                            // code styles the renderer applies itself.
                            MarkdownText(text: displayedAnswer)
                                .foregroundStyle(MTTheme.textPrimary)
                                .textSelection(.enabled)
                        }
                        if !hasDisplayedAnswer && !hasDisplayedReasoning {
                            Text(placeholder)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(MTTheme.textTertiary)
                        }
                        if showsMissingAnswerNote {
                            Text(L("The model used the whole token budget on reasoning and produced no final answer."))
                                .font(MTTheme.body(10.5))
                                .foregroundStyle(MTTheme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: MTStreamBottomKey.self,
                                value: geometry.frame(in: .named("streamScroll")).maxY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "streamScroll")
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: MTStreamViewportKey.self,
                            value: geometry.size.height
                        )
                    }
                )
                .onPreferenceChange(MTStreamBottomKey.self) { bottom in
                    contentBottom = bottom
                    updateFollow()
                }
                .onPreferenceChange(MTStreamViewportKey.self) { height in
                    viewportHeight = height
                    updateFollow()
                }
                .onChange(of: displayedAnswer) { _, _ in followIfNeeded(proxy) }
                .onChange(of: displayedReasoning) { _, _ in followIfNeeded(proxy) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MTTheme.cardSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var reasoningHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "brain")
                .font(.system(size: 9.5, weight: .semibold))
            Text(L("Reasoning"))
                .font(MTTheme.body(10, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(MTTheme.textTertiary)
        .help(L("The model's scratchpad. It is not part of the answer."))
    }

    private var placeholder: String {
        switch phase {
        case .startingEngine:
            return L("Starting the engine...")
        case .generating:
            return L("Waiting for the first token...")
        default:
            return L("No response yet. Click 'Run Test Completion' above.")
        }
    }

    /// Auto-follow only when the reader is at the bottom; scrolling up while
    /// the model streams must not yank the view back.
    private func updateFollow() {
        guard viewportHeight > 0 else { return }
        isNearBottom = contentBottom <= viewportHeight + 40
    }

    private func followIfNeeded(_ proxy: ScrollViewProxy) {
        guard isNearBottom else { return }
        if reduceMotion {
            proxy.scrollTo("bottom", anchor: .bottom)
        } else {
            withAnimation(.linear(duration: 0.1)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Engine run

    private func runTest(forceSwitch: Bool = false) {
        guard activeTask == nil, !isProbingTool, !isRunningGateway else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !forceSwitch, runtime.status.isRunning,
           let current = runtime.currentModel, current.id != model.id {
            pendingSwitch = true
            return
        }

        answer = ""
        reasoning = ""
        displayedAnswer = ""
        displayedReasoning = ""
        answerBatcher = MTTextBatcher()
        reasoningBatcher = MTTextBatcher()
        stats = LocalAIStreamStats()
        elapsed = 0
        truncated = false
        toolProbe = nil
        phase = .startingEngine

        let startedAt = Date()
        startTicker(from: startedAt)

        activeTask = Task { @MainActor in
            do {
                let isAlreadyRunning: Bool = {
                    if case .running(_, let id) = runtime.status { return id == model.id }
                    return false
                }()

                if !isAlreadyRunning {
                    try await runtime.loadModel(model)
                }

                guard !Task.isCancelled else { return }
                phase = .generating
                try await streamCompletion(prompt: text, startedAt: startedAt)
                if !Task.isCancelled {
                    phase = .finished
                }
            } catch is CancellationError {
                phase = .finished
            } catch {
                if !Task.isCancelled {
                    phase = .failed(Self.describe(error))
                }
            }
            finishStreams()
            ticker?.cancel()
            ticker = nil
            activeTask = nil
        }
    }

    private func streamCompletion(prompt text: String, startedAt: Date) async throws {
        guard let base = URL(string: "http://127.0.0.1:\(runtime.port)") else {
            throw LocalAIRequestError(status: nil, code: nil, message: L("Invalid endpoint URL"))
        }
        let payload: [String: Any] = [
            "model": model.id,
            "messages": [["role": "user", "content": text]],
            "temperature": model.userSettings.temperature,
            "max_tokens": Self.maxTokens,
            "stream": true,
            // Asks for a final usage block; engines that ignore it still send
            // `timings`, and both beat counting SSE chunks as tokens.
            "stream_options": ["include_usage": true],
        ]
        let request = try makeRequest(
            path: "/v1/chat/completions",
            base: base,
            token: runtime.internalToken,
            body: payload,
            timeout: 300
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalAIRequestError(status: nil, code: nil, message: L("No HTTP response"))
        }
        guard (200...299).contains(http.statusCode) else {
            let body = await Self.bodyText(from: bytes)
            throw LocalAIRequestError.parse(status: http.statusCode, body: body)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let chunk = LocalAIStreamChunk.parse(line: line) else { continue }
            if chunk.done { break }

            let now = Date()
            if !chunk.reasoning.isEmpty {
                reasoning += chunk.reasoning
                if let published = reasoningBatcher.append(chunk.reasoning, now: now) {
                    displayedReasoning = published
                }
            }
            if !chunk.content.isEmpty {
                answer += chunk.content
                if let published = answerBatcher.append(chunk.content, now: now) {
                    displayedAnswer = published
                }
            }
            stats.note(chunk)
            if chunk.finishReason == "length" {
                truncated = true
            }
        }

        finishStreams()
    }

    private func startTicker(from start: Date) {
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(start)
                flushStreams()
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    /// Publishes at most one text update per `MTTextBatcher.interval`, so the
    /// Markdown renderer does not run on every token.
    private func flushStreams() {
        let now = Date()
        if let published = answerBatcher.flushIfDue(now: now) { displayedAnswer = published }
        if let published = reasoningBatcher.flushIfDue(now: now) { displayedReasoning = published }
    }

    private func finishStreams() {
        let now = Date()
        if let published = answerBatcher.flush(now: now) { displayedAnswer = published }
        if let published = reasoningBatcher.flush(now: now) { displayedReasoning = published }
    }

    private func cancelRun() {
        activeTask?.cancel()
        activeTask = nil
        ticker?.cancel()
        ticker = nil
        isProbingTool = false
        isRunningGateway = false
        finishStreams()
        if phase == .startingEngine || phase == .generating {
            phase = .finished
        }
    }

    private func clearRun() {
        answer = ""
        reasoning = ""
        displayedAnswer = ""
        displayedReasoning = ""
        answerBatcher = MTTextBatcher()
        reasoningBatcher = MTTextBatcher()
        stats = LocalAIStreamStats()
        elapsed = 0
        truncated = false
        toolProbe = nil
        gatewayChecks = []
        phase = .idle
    }

    // MARK: - Tool probe

    /// Sends one request with a virtual tool and checks that the model answers
    /// with a structured `tool_calls` array instead of prose. The virtual tool
    /// never executes: only protocol compliance is measured (§22).
    private func runToolProbe() {
        guard activeTask == nil, !isProbingTool else { return }
        if runtime.status.isRunning,
           let current = runtime.currentModel, current.id != model.id {
            toolProbe = .failure(L("Another model is running. Stop it first."))
            return
        }
        isProbingTool = true
        toolProbe = nil

        activeTask = Task { @MainActor in
            defer {
                isProbingTool = false
                activeTask = nil
            }
            let isAlreadyRunning: Bool = {
                if case .running(_, let id) = runtime.status { return id == model.id }
                return false
            }()
            do {
                if !isAlreadyRunning {
                    try await runtime.loadModel(model)
                }
                toolProbe = try await requestToolCall()
            } catch is CancellationError {
                toolProbe = .failure(L("Cancelled"))
            } catch {
                toolProbe = .failure(Self.describe(error))
            }
        }
    }

    private func requestToolCall() async throws -> ToolProbeResult {
        guard let base = URL(string: "http://127.0.0.1:\(runtime.port)") else {
            throw LocalAIRequestError(status: nil, code: nil, message: L("Invalid endpoint URL"))
        }
        let body: [String: Any] = [
            "model": model.id,
            "messages": [["role": "user", "content": "What is the weather in Paris? Use the tool."]],
            "tools": [Self.weatherTool],
            "tool_choice": "auto",
            "stream": false,
            "max_tokens": 512,
        ]
        let request = try makeRequest(
            path: "/v1/chat/completions",
            base: base,
            token: runtime.internalToken,
            body: body,
            timeout: 180
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            let body = String(decoding: data, as: UTF8.self)
            return .failure(LocalAIRequestError.parse(status: status, body: body).errorDescription ?? "HTTP \(status)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(L("The endpoint did not return JSON"))
        }
        return Self.toolCallResult(from: json)
    }

    static var weatherTool: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "get_weather",
                "description": "Get the current weather for a city",
                "parameters": [
                    "type": "object",
                    "properties": ["city": ["type": "string"]],
                    "required": ["city"],
                ],
            ],
        ]
    }

    private static func toolCallResult(from json: [String: Any]) -> ToolProbeResult {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let calls = message["tool_calls"] as? [[String: Any]],
              let first = calls.first,
              let function = first["function"] as? [String: Any],
              let name = function["name"] as? String else {
            return .failure(L("The model returned no tool call"))
        }
        let arguments = (function["arguments"] as? String) ?? ""
        return .success(name: name, arguments: arguments)
    }

    // MARK: - Gateway E2E

    private func runGatewayChecks() {
        guard activeTask == nil else { return }
        let checks = Self.gatewayChecklist.map {
            LocalAIGatewayCheck(id: $0.id, title: $0.title, state: .pending)
        }
        gatewayChecks = checks
        isRunningGateway = true
        let startedAt = Date()
        startTicker(from: startedAt)

        activeTask = Task { @MainActor in
            defer {
                isRunningGateway = false
                activeTask = nil
                ticker?.cancel()
                ticker = nil
                elapsed = Date().timeIntervalSince(startedAt)
            }
            for index in checks.indices {
                guard !Task.isCancelled else {
                    gatewayChecks[index].state = .failed(L("Cancelled"))
                    continue
                }
                let begin = Date()
                gatewayChecks[index].state = .running
                let outcome = await runGatewayCheck(checks[index].id)
                let milliseconds = Int(Date().timeIntervalSince(begin) * 1000)
                switch outcome {
                case .passed(let detail):
                    let suffix = detail.isEmpty ? "" : " · \(detail)"
                    gatewayChecks[index].state = .passed("\(milliseconds) ms\(suffix)")
                case .failed(let message):
                    gatewayChecks[index].state = .failed(message)
                }
            }
        }
    }

    private enum GatewayOutcome {
        case passed(String)
        case failed(String)
    }

    private var gatewayBase: String { "http://127.0.0.1:\(gateway.port)" }
    private var gatewayToken: String { gateway.apiKey }

    private func runGatewayCheck(_ id: String) async -> GatewayOutcome {
        switch id {
        case "chat": return await gatewayChat(stream: false, tools: false)
        case "chatStream": return await gatewayChat(stream: true, tools: false)
        case "responses": return await gatewayResponses(stream: false)
        case "responsesStream": return await gatewayResponses(stream: true)
        case "tools": return await gatewayChat(stream: false, tools: true)
        case "cancel": return await gatewayCancel()
        default: return .failed(L("Unknown check"))
        }
    }

    private func gatewayChat(stream: Bool, tools: Bool) async -> GatewayOutcome {
        var body: [String: Any] = [
            "model": model.id,
            "messages": [["role": "user", "content": "Say hello in one short sentence."]],
            "max_tokens": 96,
            "stream": stream,
        ]
        if tools {
            body["messages"] = [["role": "user", "content": "What is the weather in Paris? Use the tool."]]
            body["tools"] = [Self.weatherTool]
            body["tool_choice"] = "auto"
        }
        do {
            guard let base = URL(string: gatewayBase) else {
                return .failed(L("Invalid endpoint URL"))
            }
            let request = try makeRequest(
                path: "/v1/chat/completions",
                base: base,
                token: gatewayToken,
                body: body,
                timeout: 180
            )
            return try await performGatewayChat(request, streaming: stream, expectsTool: tools)
        } catch is CancellationError {
            return .failed(L("Cancelled"))
        } catch {
            return .failed(Self.describe(error))
        }
    }

    private func performGatewayChat(
        _ request: URLRequest,
        streaming: Bool,
        expectsTool: Bool
    ) async throws -> GatewayOutcome {
        if !streaming {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                let body = String(decoding: data, as: UTF8.self)
                return .failed(LocalAIRequestError.parse(status: status, body: body).errorDescription ?? "HTTP \(status)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed(L("The gateway did not return JSON"))
            }
            if expectsTool {
                if case .success = Self.toolCallResult(from: json) {
                    return .passed(L("tool_calls"))
                }
                return .failed(L("The gateway returned no tool call"))
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                return .failed(L("No choices in the response"))
            }
            let text = (message["content"] as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failed(L("Empty message"))
            }
            return .passed("\(text.count) " + L("chars"))
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            let body = await Self.bodyText(from: bytes)
            return .failed(LocalAIRequestError.parse(status: status, body: body).errorDescription ?? "HTTP \(status)")
        }
        var deltas = 0
        var finished = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let chunk = LocalAIStreamChunk.parse(line: line) else { continue }
            if chunk.done { finished = true; break }
            if !chunk.content.isEmpty || !chunk.reasoning.isEmpty { deltas += 1 }
            if let reason = chunk.finishReason, !reason.isEmpty { finished = true }
        }
        guard deltas > 0 else { return .failed(L("No streamed deltas")) }
        return .passed("\(deltas) " + L("deltas") + (finished ? "" : " · " + L("no final event")))
    }

    private func gatewayResponses(stream: Bool) async -> GatewayOutcome {
        let body: [String: Any] = [
            "model": model.id,
            "input": "Say hello in one short sentence.",
            "max_output_tokens": 96,
            "stream": stream,
        ]
        do {
            guard let base = URL(string: gatewayBase) else {
                return .failed(L("Invalid endpoint URL"))
            }
            let request = try makeRequest(
                path: "/v1/responses",
                base: base,
                token: gatewayToken,
                body: body,
                timeout: 180
            )
            if !stream {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200...299).contains(status) else {
                    let text = String(decoding: data, as: UTF8.self)
                    return .failed(LocalAIRequestError.parse(status: status, body: text).errorDescription ?? "HTTP \(status)")
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let output = json["output"] as? [[String: Any]],
                      !output.isEmpty else {
                    return .failed(L("No output items in the response"))
                }
                return .passed("\(output.count) " + L("output items"))
            }

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                let text = await Self.bodyText(from: bytes)
                return .failed(LocalAIRequestError.parse(status: status, body: text).errorDescription ?? "HTTP \(status)")
            }
            var events = 0
            var completed = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("event:") {
                    events += 1
                    if trimmed.contains("response.completed") { completed = true }
                }
                if trimmed == "data: [DONE]" { break }
            }
            guard events > 0 else { return .failed(L("No streamed events")) }
            return .passed(completed ? L("completed") : "\(events) " + L("events"))
        } catch is CancellationError {
            return .failed(L("Cancelled"))
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// Starts a streaming request and stops it mid-flight: the point is that
    /// Stop cancels the HTTP request instead of leaving it running.
    private func gatewayCancel() async -> GatewayOutcome {
        guard let base = URL(string: gatewayBase) else {
            return .failed(L("Invalid endpoint URL"))
        }
        do {
            let payload: [String: Any] = [
                "model": model.id,
                "messages": [["role": "user", "content": "Count from 1 to 200, one number per line."]],
                "max_tokens": 512,
                "stream": true,
            ]
            let request = try makeRequest(
                path: "/v1/chat/completions",
                base: base,
                token: gatewayToken,
                body: payload,
                timeout: 180
            )
            let stream = Task { () -> Int in
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200...299).contains(status) else { return -1 }
                var deltas = 0
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    if let chunk = LocalAIStreamChunk.parse(line: line), !chunk.content.isEmpty {
                        deltas += 1
                    }
                }
                return deltas
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            stream.cancel()
            _ = try? await stream.value
            return .passed(L("Stopped without a crash"))
        } catch is CancellationError {
            return .failed(L("Cancelled"))
        } catch {
            return .failed(Self.describe(error))
        }
    }

    // MARK: - Transport helpers

    private func makeRequest(
        path: String,
        base: URL,
        token: String,
        body: [String: Any],
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: base.absoluteString + path) else {
            throw LocalAIRequestError(status: nil, code: nil, message: L("Invalid endpoint URL"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        return request
    }

    /// Error responses are read here so the body is not thrown away with the
    /// status code.
    private static func bodyText(from bytes: URLSession.AsyncBytes, limit: Int = 65_536) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            // A truncated body is still better than "HTTP N".
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ error: Error) -> String {
        if let requestError = error as? LocalAIRequestError {
            return requestError.errorDescription ?? requestError.message
        }
        return error.localizedDescription
    }
}

// MARK: - Scroll preferences

private struct MTStreamBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MTStreamViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
