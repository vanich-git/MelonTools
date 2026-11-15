import SwiftUI

/// Hub model cards use Markdown tables in addition to the chat renderer's
/// headings, lists and fenced code. Most cards also embed raw HTML — centred
/// logos, badges, `<details>` blocks and whole tables — so the HTML is
/// rewritten into its Markdown equivalent first. Nothing is ever executed.
struct HFReadmeView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.sections(Self.htmlToMarkdown(text)).enumerated()), id: \.offset) { _, section in
                if let header = section.header {
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow {
                                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                                    Text(.init(cell)).bold()
                                }
                            }
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                Divider().gridCellColumns(header.count)
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        Text(.init(cell)).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        .font(MTTheme.body(11))
                        .padding(10)
                    }
                    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 6))
                } else {
                    MarkdownText(text: section.markdown, baseSize: 12)
                }
            }
        }
        .textSelection(.enabled)
    }

    struct Section: Equatable {
        var markdown = ""
        var header: [String]? = nil
        var rows: [[String]] = []
    }

    static func sections(_ source: String) -> [Section] {
        var lines = source.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) {
            lines.removeFirst(end + 1)
        }
        var result: [Section] = []
        var markdown: [String] = []
        var inCode = false
        var index = 0
        func cells(_ line: String) -> [String] {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }
            if value.hasSuffix("|") { value.removeLast() }
            // Preserve escaped pipes inside a cell.
            return value.replacingOccurrences(of: "\\|", with: "\u{001F}")
                .components(separatedBy: "|").map {
                    $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{001F}", with: "|")
                }
        }
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            if !inCode, index + 1 < lines.count, line.contains("|") {
                let separator = cells(lines[index + 1])
                if !separator.isEmpty, separator.count == cells(line).count,
                   separator.allSatisfy({ cell in
                       let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                       return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" }
                   }) {
                    if !markdown.isEmpty { result.append(Section(markdown: markdown.joined(separator: "\n"))); markdown = [] }
                    let header = cells(line)
                    var rows: [[String]] = []
                    index += 2
                    while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        var row = Array(cells(lines[index]).prefix(header.count))
                        row += Array(repeating: "", count: max(0, header.count - row.count))
                        rows.append(row)
                        index += 1
                    }
                    result.append(Section(header: header, rows: rows))
                    continue
                }
            }
            markdown.append(line)
            index += 1
        }
        if !markdown.isEmpty { result.append(Section(markdown: markdown.joined(separator: "\n"))) }
        return result
    }

    // MARK: - Raw HTML in model cards

    /// Model cards mix Markdown with raw HTML. Left as-is, the tags reached the
    /// screen as one glued paragraph of `<p align="center">…`. The common
    /// constructs are rewritten into Markdown, unknown tags are dropped and
    /// their text kept, and fenced code is never touched.
    static func htmlToMarkdown(_ source: String) -> String {
        var codeBlocks: [String] = []
        var text = replacing("```[\\s\\S]*?```", in: source) { groups in
            codeBlocks.append(groups[0])
            return "\u{0001}CODE\(codeBlocks.count - 1)\u{0001}"
        }
        // Model cards carry Hugging Face metadata as HTML comments
        // (`<!-- ### quantize_version: 2 -->`, `<!-- provided-files -->`).
        // A browser hides them; without this they reach the screen as text.
        text = replacing("<!--[\\s\\S]*?-->", in: text) { _ in "" }
        text = replacing("<table[\\s\\S]*?</table>", in: text) { tableMarkdown($0[0]) }
        text = replacing("<br\\s*/?>", in: text) { _ in "\n" }
        text = replacing("</(p|div|section|article|details|summary|h[1-6]|ul|ol|tr)>", in: text) { _ in "\n\n" }
        text = replacing("<h([1-6])[^>]*>", in: text) { groups in
            "\n\n" + String(repeating: "#", count: Int(groups[1]) ?? 2) + " "
        }
        text = replacing("<li[^>]*>", in: text) { _ in "- " }
        text = replacing("</li>", in: text) { _ in "\n" }
        text = replacing("<hr\\s*/?>", in: text) { _ in "\n\n---\n\n" }
        text = replacing("</?(strong|b)>", in: text) { _ in "**" }
        text = replacing("</?(em|i)>", in: text) { _ in "*" }
        text = replacing("</?code>", in: text) { _ in "`" }
        // A link wrapped around a bare image is a badge: keep the caption, drop the artwork.
        text = replacing("<a\\s[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>\\s*(<img\\s[^>]*>)\\s*</a>", in: text) { groups in
            let href = groups[1]
            guard isWebLink(href) else { return "" }
            let alt = attribute("alt", in: groups[2]) ?? ""
            return alt.isEmpty ? "" : "[\(alt)](\(href))"
        }
        text = replacing("<a\\s[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>", in: text) { groups in
            let label = stripHTML(groups[2])
            guard isWebLink(groups[1]) else { return label }
            return "[\(label.isEmpty ? groups[1] : label)](\(groups[1]))"
        }
        text = replacing("<img\\s[^>]*>", in: text) { groups in
            guard let source = attribute("src", in: groups[0]), isWebLink(source) else { return "" }
            let alt = attribute("alt", in: groups[0]) ?? ""
            return "[\(alt.isEmpty ? "image" : alt)](\(source))"
        }
        // Neither renderer draws remote images: keep the caption so badges read as links.
        text = replacing("!\\[([^\\]]*)\\]\\([^)]*\\)", in: text) { groups in groups[1] }
        text = replacing("</?[a-zA-Z][^>]*>", in: text) { _ in "" }
        text = decodeHTMLEntities(text)
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        for (index, block) in codeBlocks.enumerated() {
            text = text.replacingOccurrences(of: "\u{0001}CODE\(index)\u{0001}", with: block)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableMarkdown(_ html: String) -> String {
        let rows = matches("<tr[^>]*>([\\s\\S]*?)</tr>", in: html).map { row in
            matches("<t[hd][^>]*>([\\s\\S]*?)</t[hd]>", in: row[1]).map {
                stripHTML($0[1]).replacingOccurrences(of: "|", with: "\\|")
            }
        }.filter { !$0.isEmpty }
        guard let header = rows.first else { return "" }
        let width = rows.map(\.count).max() ?? 0
        let line: ([String]) -> String = { cells in
            "| " + (0..<width).map { $0 < cells.count ? cells[$0] : "" }.joined(separator: " | ") + " |"
        }
        let separator = "|" + String(repeating: " --- |", count: width)
        return "\n\n" + ([line(header), separator] + rows.dropFirst().map(line)).joined(separator: "\n") + "\n\n"
    }

    private static func stripHTML(_ value: String) -> String {
        decodeHTMLEntities(replacing("<[^>]*>", in: value) { _ in " " })
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        matches("\(name)\\s*=\\s*[\"']([^\"']*)[\"']", in: tag).first.map { $0[1] }
    }

    private static func isWebLink(_ value: String) -> Bool {
        guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func decodeHTMLEntities(_ source: String) -> String {
        // `&amp;` is decoded last so `&amp;lt;` stays the literal `&lt;`.
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&"),
        ]
        var text = source
        for (entity, value) in named {
            text = text.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        text = replacing("&#x([0-9a-f]+);", in: text) { groups in
            UInt32(groups[1], radix: 16).flatMap(UnicodeScalar.init).map(String.init) ?? groups[0]
        }
        return replacing("&#([0-9]+);", in: text) { groups in
            UInt32(groups[1]).flatMap(UnicodeScalar.init).map(String.init) ?? groups[0]
        }
    }

    /// Matches right to left so earlier replacements keep their offsets valid.
    private static func replacing(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return text }
        let source = text as NSString
        let found = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var result = text
        for match in found.reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(groups))
        }
        return result
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
}
