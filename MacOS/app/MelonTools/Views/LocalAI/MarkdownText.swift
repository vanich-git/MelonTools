import SwiftUI

/// Renders the assistant's Markdown in a SwiftUI view.
///
/// SwiftUI's `Text` only understands *inline* Markdown: `AttributedString`
/// drops `#` headings, `-` bullets and fenced code blocks, so a model answer
/// arrived on screen as literal `### **Заголовок**`. This view splits the text
/// into blocks and lays each one out explicitly.
struct MarkdownText: View {
    let text: String
    var baseSize: CGFloat = 12
    var tint: Color = MTTheme.textPrimary

    /// Streaming answers re-render on every 60 ms batch; re-parsing the whole
    /// accumulated text each time made the work grow with the answer length.
    /// The cache parses the stable prefix once and only the unfinished tail
    /// again (see `MTMarkdownCache`).
    @State private var cache = MTMarkdownCache()

    var body: some View {
        let blocks = cache.blocks(for: text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Blocks

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(text: String, indent: Int)
        case numbered(marker: String, text: String, indent: Int)
        case quote(String)
        case code(String)
        case rule
    }

    /// Splits Markdown into renderable blocks. Deliberately small: it covers
    /// what chat models actually emit, not the full CommonMark grammar.
    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            // Headings.
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            // Blockquote.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(content))
                continue
            }

            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count / 2

            // Bullets: -, *, •, and unicode bullets some models emit.
            if let bullet = bulletContent(trimmed) {
                flushParagraph()
                blocks.append(.bullet(text: bullet, indent: indent))
                continue
            }

            // Numbered list: "1." "2)" "1)".
            if let numbered = numberedContent(trimmed) {
                flushParagraph()
                blocks.append(.numbered(marker: numbered.marker, text: numbered.text, indent: indent))
                continue
            }

            paragraph.append(trimmed)
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// Length of the prefix that can no longer change: it ends after the last
    /// blank line that is outside a fenced code block.
    ///
    /// A blank line is a block boundary in `parse`, so `parse(stable) + parse(tail)`
    /// is the same as `parse(stable + tail)` — the invariant the cache relies
    /// on. `nil` means the whole text is still one unfinished block.
    static func stableBoundary(in source: String) -> Int? {
        var boundary: Int?
        var offset = 0
        var inCode = false
        let lines = source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle() }
            offset += line.count
            let isLast = index == lines.count - 1
            if !isLast { offset += 1 }
            if !inCode, !isLast, trimmed.isEmpty, offset > 0 {
                boundary = offset
            }
        }
        return boundary
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard level > 0, level <= 6 else { return nil }
        // Models occasionally emit `###Заголовок` without the space.
        let rest = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (level, rest)
    }

    private static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedContent(_ line: String) -> (marker: String, text: String)? {
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex else { return nil }
        let separator = line[index]
        guard separator == "." || separator == ")" else { return nil }
        let rest = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (digits + String(separator), rest)
    }

    // MARK: - Rendering

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(MTTheme.body(headingSize(level), weight: .bold))
                .foregroundStyle(tint)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            inline(text)
                .font(MTTheme.body(baseSize))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(MTTheme.body(baseSize, weight: .bold))
                    .foregroundStyle(MTTheme.emerald)
                inline(text)
                    .font(MTTheme.body(baseSize))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .numbered(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(MTTheme.body(baseSize, weight: .semibold))
                    .foregroundStyle(MTTheme.emerald)
                    .monospacedDigit()
                inline(text)
                    .font(MTTheme.body(baseSize))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(MTTheme.textTertiary.opacity(0.5))
                    .frame(width: 2)
                inline(text)
                    .font(MTTheme.body(baseSize))
                    .foregroundStyle(MTTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let code):
            Text(code)
                .font(.system(size: baseSize - 1, design: .monospaced))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 5
        case 2: return baseSize + 3
        case 3: return baseSize + 1.5
        default: return baseSize + 0.5
        }
    }

    /// Inline Markdown (bold, italic, code) through AttributedString, with a
    /// plain-text fallback so malformed markup never reaches the screen.
    ///
    /// `AttributedString` rejects a block prefix such as `###` or a leading
    /// list marker, and the previous fallback only stripped `**` — hashes and
    /// asterisks still showed up in the answer.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        var plain = text
        for marker in ["###", "##", "#"] where plain.hasPrefix(marker) {
            plain = String(plain.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        plain = plain
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        return Text(plain)
    }
}


/// Incremental parser behind `MarkdownText`.
///
/// Everything before the last stable boundary is parsed once; only the
/// unfinished tail is parsed again on the next update. The result is identical
/// to a full `MarkdownText.parse` of the whole text — the returned array is the
/// same one a full parse would produce.
final class MTMarkdownCache {
    private var stableSource = ""
    private var stableBlocks: [MarkdownText.Block] = []
    private var cachedSource = ""
    private var cachedBlocks: [MarkdownText.Block] = []

    func blocks(for text: String) -> [MarkdownText.Block] {
        if text == cachedSource { return cachedBlocks }
        if !text.hasPrefix(cachedSource) {
            // The text was replaced (new run, Clear) rather than extended.
            stableSource = ""
            stableBlocks = []
        }
        if let boundary = MarkdownText.stableBoundary(in: text), boundary > stableSource.count {
            stableSource = String(text.prefix(boundary))
            stableBlocks = MarkdownText.parse(stableSource)
        }
        let tail = String(text.dropFirst(stableSource.count))
        cachedBlocks = tail.isEmpty ? stableBlocks : stableBlocks + MarkdownText.parse(tail)
        cachedSource = text
        return cachedBlocks
    }
}


/// Coalesces streamed text so the UI updates at a fixed rate instead of once
/// per token.
///
/// Every SSE chunk used to publish a new string, which re-parsed the whole
/// Markdown answer on the main actor. The batcher holds deltas and hands out a
/// snapshot at most once per `interval`; the caller flushes the remainder when
/// the stream ends.
struct MTTextBatcher: Equatable {
    var interval: TimeInterval
    private(set) var published = ""
    private var pending = ""
    private(set) var lastPublish = Date.distantPast

    init(interval: TimeInterval = 0.06) {
        self.interval = interval
    }

    /// Appends a delta and returns the text to publish when the interval has
    /// elapsed, or `nil` while the batch is still collecting.
    mutating func append(_ delta: String, now: Date) -> String? {
        pending += delta
        return flushIfDue(now: now)
    }

    mutating func flushIfDue(now: Date) -> String? {
        guard !pending.isEmpty, now.timeIntervalSince(lastPublish) >= interval else { return nil }
        return flush(now: now)
    }

    /// Publishes the pending batch regardless of the interval (end of stream).
    mutating func flush(now: Date = Date()) -> String? {
        guard !pending.isEmpty else { return nil }
        published += pending
        pending = ""
        lastPublish = now
        return published
    }
}
