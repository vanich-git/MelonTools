import SwiftUI

/// Hub model cards use Markdown tables in addition to the chat renderer's
/// headings, lists and fenced code. HTML is displayed as text, never executed.
struct HFReadmeView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.sections(text).enumerated()), id: \.offset) { _, section in
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
}
