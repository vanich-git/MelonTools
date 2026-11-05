import SwiftUI
import AppKit

/// Per-model settings sheet.
///
/// Layout notes: the profile presets used to be a segmented `Picker`. Five
/// localised labels ("Производительность", "Экономия памяти", …) do not fit a
/// ~500pt sheet, and a segmented picker cannot wrap, so it forced the whole
/// sheet wider than its `.frame` and every row got clipped on the left. The
/// presets are chips in a wrapping flow layout instead, and all numeric rows
/// share one fixed-width field so the labels stay aligned.
struct LocalModelSettingsSheet: View {
    @ObservedObject var store = LocalModelStore.shared
    @Binding var model: LocalModel
    @Environment(\.dismiss) private var dismiss

    @State private var contextLength: Int
    @State private var maxTokens: Int
    @State private var temperature: Double
    @State private var topP: Double
    @State private var topK: Int
    @State private var repeatPenalty: Double
    @State private var gpuOffloadLayers: Int
    @State private var cpuThreads: Int
    @State private var flashAttention: Bool
    @State private var kvCacheType: String
    @State private var chatTemplate: String
    @State private var systemPrompt: String
    @State private var profile: ModelConfigProfile
    @State private var reasoningEnabled: Bool

    private static let sheetWidth: CGFloat = 560
    private static let sheetHeight: CGFloat = 660
    private static let fieldWidth: CGFloat = 92

    init(model: Binding<LocalModel>) {
        self._model = model
        let s = model.wrappedValue.userSettings
        _contextLength = State(initialValue: s.contextLength)
        _maxTokens = State(initialValue: s.maxOutputTokens ?? 4096)
        _temperature = State(initialValue: s.temperature)
        _topP = State(initialValue: s.topP)
        _topK = State(initialValue: s.topK)
        _repeatPenalty = State(initialValue: s.repeatPenalty)
        _gpuOffloadLayers = State(initialValue: s.gpuOffloadLayers ?? 999)
        _cpuThreads = State(initialValue: s.cpuThreads ?? LocalHardwareService.shared.hardwareInfo.cpuCores)
        _flashAttention = State(initialValue: s.flashAttention)
        _kvCacheType = State(initialValue: s.kvCacheType)
        _chatTemplate = State(initialValue: s.chatTemplate ?? "auto")
        _systemPrompt = State(initialValue: s.systemPrompt ?? "")
        _profile = State(initialValue: s.profile)
        _reasoningEnabled = State(initialValue: s.isReasoningOn)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.primary.opacity(0.08))
            content
            Divider().overlay(Color.primary.opacity(0.08))
            footer
        }
        .frame(
            minWidth: 520, idealWidth: Self.sheetWidth, maxWidth: 680,
            minHeight: 480, idealHeight: Self.sheetHeight, maxHeight: 760
        )
        .background(MTTheme.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: MTTheme.s3) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MTTheme.emerald)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(MTTheme.body(14, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                Text(model.id)
                    .font(MTTheme.body(11))
                    .foregroundStyle(MTTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: MTTheme.s2)

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
        }
        .padding(.horizontal, MTTheme.s4)
        .padding(.vertical, MTTheme.s3)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Content

    private var content: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                systemPromptCard
                profileCard
                computeCard
                samplingCard
                chatTemplateCard
            }
            .padding(.horizontal, MTTheme.s4)
            .padding(.top, MTTheme.s4)
            // Keeps the last card clear of the fixed footer instead of letting
            // it slide underneath while scrolled to the bottom.
            .padding(.bottom, MTTheme.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - System prompt

    /// Sits above the profile presets on purpose: it is the one setting that
    /// changes what the model *says*, not how it runs.
    private var systemPromptCard: some View {
        MTCard(title: L("System Prompt"), systemImage: "text.quote", accent: MTTheme.gold) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(MTTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 78)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(MTTheme.cardSoft)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .accessibilityLabel(L("System Prompt"))
                Text(L("Added to every Chat Completions and Responses request this model serves through the local gateway. Empty sends none."))
                    .font(MTTheme.body(10))
                    .foregroundStyle(MTTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profileCard: some View {
        MTCard(title: L("Configuration Profile"), systemImage: "sparkles", accent: MTTheme.violet) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(ModelConfigProfile.allCases) { preset in
                        profileChip(preset)
                    }
                }

                Text(profileSummary)
                    .font(MTTheme.body(10.5))
                    .foregroundStyle(MTTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A preset chip must stop looking selected as soon as one of the values
    /// it controls is edited; otherwise the sheet claims "Performance" while
    /// saving a custom context/KV combination.
    private var effectiveProfile: ModelConfigProfile {
        guard profile != .custom else { return .custom }
        return matches(profile) ? profile : .custom
    }

    private func matches(_ preset: ModelConfigProfile) -> Bool {
        switch preset {
        case .auto, .balanced:
            return contextLength == 8192 && gpuOffloadLayers == 999
                && flashAttention && kvCacheType == "f16"
        case .performance:
            return contextLength == 16384 && gpuOffloadLayers == 999
                && flashAttention && kvCacheType == "f16"
        case .memorySaver:
            return contextLength == 4096 && gpuOffloadLayers == 32
                && flashAttention && kvCacheType == "q4_0"
        case .custom:
            return false
        }
    }

    private func profileChip(_ preset: ModelConfigProfile) -> some View {
        let isSelected = effectiveProfile == preset
        return Button(action: { selectProfile(preset) }) {
            Text(L(preset.rawValue))
                .font(MTTheme.body(11.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : MTTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        isSelected ? MTTheme.violet.opacity(0.9) : Color.primary.opacity(0.06)
                    )
                )
                .overlay(
                    Capsule().stroke(
                        isSelected ? Color.clear : Color.primary.opacity(0.09),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    private var profileSummary: String {
        switch effectiveProfile {
        case .auto:
            return L("Uses the hardware defaults: full GPU offload and a context the machine can hold.")
        case .balanced:
            return L("Even split between context size and memory headroom.")
        case .performance:
            return L("Full GPU offload and a larger context for the fastest answers the hardware allows.")
        case .memorySaver:
            return L("Offloads fewer layers and compresses the KV cache to free memory.")
        case .custom:
            return L("Your own values. Nothing is overwritten while you edit.")
        }
    }

    private var computeCard: some View {
        MTCard(title: L("Compute & Metal Acceleration"), systemImage: "cpu", accent: MTTheme.emerald) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                settingRow(L("Context Window (Tokens)")) {
                    intField($contextLength, minimum: 512, label: L("Context Window (Tokens)"))
                }
                settingRow(L("Max Output Tokens")) {
                    intField($maxTokens, minimum: 128, label: L("Max Output Tokens"))
                }
                if maxTokens > contextLength {
                    Text(L("Max output tokens cannot exceed the context window."))
                        .font(MTTheme.body(10))
                        .foregroundStyle(MTTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                settingRow(L("GPU Offload Layers (-ngl)")) {
                    intField($gpuOffloadLayers, minimum: 0, label: L("GPU Offload Layers (-ngl)"))
                }
                Text(L("Set to 999 for full Metal GPU offload, or 0 for CPU only."))
                    .font(MTTheme.body(10))
                    .foregroundStyle(MTTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                settingRow(L("CPU Worker Threads")) {
                    intField($cpuThreads, minimum: 1, label: L("CPU Worker Threads"))
                }

                Divider().overlay(Color.primary.opacity(0.06))

                HStack(alignment: .top, spacing: MTTheme.s3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Flash Attention (-fa)"))
                            .font(MTTheme.body(12, weight: .medium))
                            .foregroundStyle(MTTheme.textPrimary)
                        Text(L("Reduces memory consumption for large contexts."))
                            .font(MTTheme.body(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: MTTheme.s2)
                    Toggle("", isOn: $flashAttention)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel(L("Flash Attention (-fa)"))
                }

                HStack(alignment: .top, spacing: MTTheme.s3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Model reasoning"))
                            .font(MTTheme.body(12, weight: .medium))
                            .foregroundStyle(MTTheme.textPrimary)
                        Text(L("Lets the model think before answering. Small models may spend the whole budget thinking and return nothing."))
                            .font(MTTheme.body(10))
                            .foregroundStyle(MTTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: MTTheme.s2)
                    Toggle("", isOn: $reasoningEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel(L("Model reasoning"))
                }

                settingRow(L("KV Cache Quantization")) {
                    // Every type llama-server b12099 accepts for -ctk/-ctv.
                    MTSelect(selection: $kvCacheType, options: LocalHardwareService.supportedKVCacheTypes.map { type in
                        (type, kvCacheLabel(type))
                    })
                }

                estimationRow
            }
        }
    }

    private var samplingCard: some View {
        MTCard(title: L("Sampling Parameters"), systemImage: "waveform.path", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                sliderRow(L("Temperature"), value: $temperature, range: 0...2, step: 0.05)
                sliderRow(L("Top P"), value: $topP, range: 0...1, step: 0.05)
                sliderRow(L("Repeat Penalty"), value: $repeatPenalty, range: 1...2, step: 0.05)
                settingRow(L("Top K")) {
                    intField($topK, minimum: 1, label: L("Top K"))
                }
            }
        }
    }

    private var chatTemplateCard: some View {
        MTCard(title: L("Chat Template"), systemImage: "text.bubble", accent: MTTheme.amber) {
            settingRow(L("Template Format")) {
                MTSelect(selection: $chatTemplate, options: [
                    ("auto", L("Auto (Embedded in GGUF)")),
                    ("chatml", "ChatML"),
                    ("llama3", "Llama 3"),
                    ("qwen", "Qwen"),
                    ("deepseek", "DeepSeek"),
                    ("mistral", "Mistral"),
                    ("gemma", "Gemma"),
                ], width: 168)
            }
        }
    }

    // MARK: - Rows

    private func settingRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: MTTheme.s3) {
            Text(title)
                .font(MTTheme.body(12, weight: .medium))
                .foregroundStyle(MTTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: MTTheme.s2)
            control()
        }
    }

    private func kvCacheLabel(_ type: String) -> String {
        switch type {
        case "f16": return "f16 · " + L("Full precision")
        case "q8_0": return "q8_0 · " + L("Balanced")
        case "q4_0": return "q4_0 · " + L("Low memory")
        case "f32": return "f32 · 32-bit"
        case "bf16": return "bf16 · 16-bit"
        case "q5_1": return "q5_1 · 5-bit"
        case "q5_0": return "q5_0 · 5-bit"
        case "q4_1": return "q4_1 · 4-bit"
        case "iq4_nl": return "iq4_nl · 4-bit"
        default: return type
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(MTTheme.body(12, weight: .medium))
                    .foregroundStyle(MTTheme.textPrimary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            Slider(value: value, in: range, step: step)
                .tint(MTTheme.cyan)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: "%.2f", value.wrappedValue))
        }
    }

    private func intField(_ value: Binding<Int>, minimum: Int, label: String) -> some View {
        TextField("", value: value, formatter: Self.integerFormatter(minimum: minimum))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(MTTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: Self.fieldWidth)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(MTTheme.cardSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            )
            .accessibilityLabel(label)
    }

    /// Live memory estimate for the current numbers, so the sheet answers the
    /// question the sliders raise: does this still fit on the machine?
    @ViewBuilder
    private var estimationRow: some View {
        if let estimate = currentEstimate {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint(for: estimate.recommendation))
                    Text(L("Estimated memory"))
                        .font(MTTheme.body(10.5))
                        .foregroundStyle(MTTheme.textTertiary)
                    // A range, not a promise: the figure depends on allocator
                    // behaviour the app does not control.
                    Text(estimate.isRangeWide
                         ? "\(LocalHardwareService.formatBytes(estimate.totalLow))–\(LocalHardwareService.formatBytes(estimate.totalHigh))"
                         : LocalHardwareService.formatBytes(estimate.totalRequired))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(MTTheme.textSecondary)
                    Spacer(minLength: 0)
                    Text(L(estimate.recommendation.rawValue))
                        .font(MTTheme.body(10.5, weight: .medium))
                        .foregroundStyle(tint(for: estimate.recommendation))
                }
                HStack(spacing: 6) {
                    Text(String(format: L("Weights %@ · KV %@ · state %@ · reserve %@"),
                                LocalHardwareService.formatBytes(estimate.weightsSize),
                                LocalHardwareService.formatBytes(estimate.kvCacheSize),
                                LocalHardwareService.formatBytes(estimate.stateCacheSize),
                                LocalHardwareService.formatBytes(estimate.osReserve)))
                        .font(MTTheme.body(9.5))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: 0)
                    Text(String(format: L("Confidence: %@"), L(estimate.confidence.rawValue)))
                        .font(MTTheme.body(9.5, weight: .medium))
                        .foregroundStyle(estimate.confidence == .high ? MTTheme.emerald : MTTheme.amber)
                }
            }
            .padding(.top, 2)
            if let warning = estimate.warning {
                Text(warning)
                    .font(MTTheme.body(9.5))
                    .foregroundStyle(MTTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var currentEstimate: MemoryEstimation? {
        guard model.fileSize > 0 else { return nil }
        return LocalHardwareService.shared.estimateMemory(
            weightsSize: model.fileSize,
            contextLength: contextLength,
            kvCacheType: kvCacheType,
            batchSize: 512,
            gpuLayers: gpuOffloadLayers,
            totalLayers: model.blockCount ?? 32,
            profile: model.memoryProfile,
            slots: LocalInferenceService.parallelRequests,
            backend: model.backend
        )
    }

    private func tint(for recommendation: CompatibilityRecommendation) -> Color {
        switch recommendation {
        case .recommended: return MTTheme.emerald
        case .fitsWithLimitations: return MTTheme.amber
        case .highMemoryUsage: return MTTheme.amber
        case .insufficientMemory: return MTTheme.danger
        case .unsupportedArchitecture, .unknown: return MTTheme.textTertiary
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: MTTheme.s2) {
            Button(L("Reset to Defaults")) {
                resetDefaults()
            }
            .buttonStyle(.plain)
            .font(MTTheme.body(11.5))
            .foregroundStyle(MTTheme.textTertiary)

            Spacer(minLength: MTTheme.s2)

            Button(L("Cancel")) {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .controlSize(.regular)

            Button(L("Save Settings")) {
                saveSettings()
            }
            .buttonStyle(.borderedProminent)
            .tint(MTTheme.emerald)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .disabled(maxTokens > contextLength)
        }
        .padding(.horizontal, MTTheme.s4)
        .padding(.vertical, MTTheme.s3)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Actions

    private func selectProfile(_ preset: ModelConfigProfile) {
        profile = preset
        guard preset != .custom else { return }
        applyProfile(preset)
    }

    private func applyProfile(_ p: ModelConfigProfile) {
        switch p {
        case .auto, .balanced:
            contextLength = 8192
            gpuOffloadLayers = 999
            flashAttention = true
            kvCacheType = "f16"
        case .performance:
            // Performance means "use the hardware", not "shrink the window":
            // the old 4096 made the profile slower on long prompts and
            // contradicted its own description.
            contextLength = 16384
            gpuOffloadLayers = 999
            flashAttention = true
            kvCacheType = "f16"
        case .memorySaver:
            contextLength = 4096
            gpuOffloadLayers = 32
            flashAttention = true
            kvCacheType = "q4_0"
        case .custom:
            break
        }
    }

    private func resetDefaults() {
        let def = LocalModelSettings.defaultSettings(forContext: 8192)
        contextLength = def.contextLength
        maxTokens = def.maxOutputTokens ?? 4096
        temperature = def.temperature
        topP = def.topP
        topK = def.topK
        repeatPenalty = def.repeatPenalty
        gpuOffloadLayers = def.gpuOffloadLayers ?? 999
        cpuThreads = def.cpuThreads ?? LocalHardwareService.shared.hardwareInfo.cpuCores
        flashAttention = def.flashAttention
        kvCacheType = def.kvCacheType
        chatTemplate = def.chatTemplate ?? "auto"
        systemPrompt = def.systemPrompt ?? ""
        profile = .auto
        reasoningEnabled = def.isReasoningOn
    }

    /// Persists the edit and closes the sheet. Engine-level settings reach the
    /// running process on the next start; the sheet is not a status panel, so a
    /// successful save is silent and returns the user to the list.
    private func saveSettings() {
        var s = model.userSettings
        s.contextLength = contextLength
        s.maxOutputTokens = maxTokens
        s.temperature = temperature
        s.topP = topP
        s.topK = topK
        s.repeatPenalty = repeatPenalty
        s.gpuOffloadLayers = gpuOffloadLayers
        s.cpuThreads = cpuThreads
        s.flashAttention = flashAttention
        s.kvCacheType = kvCacheType
        s.chatTemplate = chatTemplate == "auto" ? nil : chatTemplate
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        s.systemPrompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt
        s.profile = effectiveProfile
        s.reasoningEnabled = reasoningEnabled

        model.userSettings = s
        model.configuredContext = contextLength
        model.gpuOffload = gpuOffloadLayers
        model.threads = cpuThreads

        store.addOrUpdateModel(model)
        dismiss()
    }

    // MARK: - Formatters

    private static func integerFormatter(minimum: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: minimum)
        return formatter
    }
}

/// Wraps children onto as many lines as the width allows. A segmented `Picker`
/// cannot do this, which is what pushed the sheet past its frame.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidths: [CGFloat] = [0]
        var lineHeights: [CGFloat] = [0]
        var line = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = lineWidths[line] > 0 ? lineWidths[line] + spacing + size.width : size.width
            if lineWidths[line] > 0, needed > maxWidth {
                line += 1
                lineWidths.append(size.width)
                lineHeights.append(size.height)
            } else {
                lineWidths[line] = needed
                lineHeights[line] = max(lineHeights[line], size.height)
            }
        }

        let height = lineHeights.reduce(0, +)
            + CGFloat(max(0, lineHeights.count - 1)) * lineSpacing
        let width = proposal.width ?? (lineWidths.max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
