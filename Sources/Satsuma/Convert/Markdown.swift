import AppKit

/// Small Markdown ↔ rich-text bridge (headings, lists, emphasis, code, links, quotes, tables).
enum Markdown {
    // MARK: Markdown → HTML

    static func html(from markdown: String) -> String {
        var html = ["<!doctype html><html><head><meta charset=\"utf-8\"><style>body{font:12pt -apple-system,Helvetica,sans-serif}code,pre{font-family:Menlo,monospace}table{border-collapse:collapse}td,th{border:1px solid #aaa;padding:4px}</style></head><body>"]
        var paragraph: [String] = []
        var listKind: String?
        var inCode = false
        var code: [String] = []
        var table: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>"); paragraph = [] }
        }
        func closeList() { if let kind = listKind { html.append("</\(kind)>"); listKind = nil } }
        func flushTable() {
            guard !table.isEmpty else { return }
            html.append("<table>")
            for (index, row) in table.enumerated() {
                let tag = index == 0 ? "th" : "td"
                html.append("<tr>" + row.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>")
            }
            html.append("</table>")
            table = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    html.append("<pre><code>\(code.joined(separator: "\n").xmlEscaped)</code></pre>"); code = []
                } else { flushParagraph(); closeList(); flushTable() }
                inCode.toggle(); continue
            }
            if inCode { code.append(rawLine); continue }
            if line.isEmpty { flushParagraph(); closeList(); flushTable(); continue }
            if line.hasPrefix("|") {
                flushParagraph(); closeList()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                table.append(cells); continue
            }
            flushTable()
            if let level = headingLevel(line) {
                flushParagraph(); closeList()
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inline(text))</h\(level)>"); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                if listKind != "ul" { closeList(); html.append("<ul>"); listKind = "ul" }
                html.append("<li>\(inline(String(line.dropFirst(2))))</li>"); continue
            }
            if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                if listKind != "ol" { closeList(); html.append("<ol>"); listKind = "ol" }
                html.append("<li>\(inline(String(line[range.upperBound...])))</li>"); continue
            }
            if line.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote>\(inline(line.dropFirst().trimmingCharacters(in: .whitespaces)))</blockquote>"); continue
            }
            if line == "---" || line == "***" { flushParagraph(); closeList(); html.append("<hr/>"); continue }
            closeList()
            paragraph.append(line)
        }
        flushParagraph(); closeList(); flushTable()
        if inCode { html.append("<pre><code>\(code.joined(separator: "\n").xmlEscaped)</code></pre>") }
        html.append("</body></html>")
        return html.joined(separator: "\n")
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func inline(_ text: String) -> String {
        var out = text.xmlEscaped
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"__([^_]+)__"#, "<b>$1</b>"),
            (#"\*([^*]+)\*"#, "<i>$1</i>"),
            (#"(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])"#, "<i>$1</i>"),
            (#"!\[([^\]]*)\]\(([^)]+)\)"#, "<img alt=\"$1\" src=\"$2\"/>"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    // MARK: Rich text → Markdown / XHTML

    struct Paragraph {
        var text: String
        var headingLevel: Int?
        var listMarker: String?
        var runs: [(String, Bool, Bool)]
    }

    /// Splits rich text into paragraphs, inferring headings from font size relative to the body text.
    static func paragraphs(from text: NSAttributedString) -> [Paragraph] {
        let string = text.string as NSString
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize, default: 0] += range.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        var result: [Paragraph] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { return }
            var runs: [(String, Bool, Bool)] = []
            var maxSize: CGFloat = 0
            var allBold = true
            text.enumerateAttributes(in: range) { attributes, runRange, _ in
                let font = attributes[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let bold = traits.contains(.boldFontMask)
                maxSize = max(maxSize, font?.pointSize ?? body)
                if !bold { allBold = false }
                runs.append((string.substring(with: runRange), bold, traits.contains(.italicFontMask)))
            }
            let plain = string.substring(with: range)
            var level: Int?
            if plain.count <= 140 {
                if maxSize >= body * 1.7 { level = 1 }
                else if maxSize >= body * 1.25 { level = 2 }
                else if allBold && plain.count < 80 && maxSize > body { level = 3 }
            }
            var marker: String?
            if let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
               let list = style.textLists.last {
                marker = list.markerFormat.rawValue.contains("decimal") ? "1." : "-"
            }
            result.append(Paragraph(text: plain, headingLevel: level, listMarker: marker, runs: runs))
        }
        return result
    }

    static func markdown(from text: NSAttributedString) -> String {
        paragraphs(from: text).map { paragraph -> String in
            var body = paragraph.runs.map { run -> String in
                let content = run.0.replacingOccurrences(of: "\t", with: " ")
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, paragraph.headingLevel == nil else { return content }
                if run.1 && run.2 { return "***\(trimmed)***" }
                if run.1 { return "**\(trimmed)**" }
                if run.2 { return "*\(trimmed)*" }
                return content
            }.joined()
            // Drop list markers that NSTextList renders inline.
            body = body.replacingOccurrences(of: #"^\s*(•|◦|▪|\d+[.)])\s*"#, with: "", options: .regularExpression)
            if let level = paragraph.headingLevel { return String(repeating: "#", count: level) + " " + body.trimmingCharacters(in: .whitespaces) }
            if let marker = paragraph.listMarker { return "\(marker) \(body.trimmingCharacters(in: .whitespaces))" }
            return body
        }.joined(separator: "\n\n") + "\n"
    }

    static func xhtmlBody(from text: NSAttributedString) -> String {
        var out: [String] = []
        var openList: String?
        for paragraph in paragraphs(from: text) {
            let content = paragraph.runs.map { run -> String in
                var piece = run.0.xmlEscaped
                if run.1 { piece = "<b>\(piece)</b>" }
                if run.2 { piece = "<i>\(piece)</i>" }
                return piece
            }.joined()
            if let marker = paragraph.listMarker {
                let tag = marker == "-" ? "ul" : "ol"
                if openList != tag { if let openList { out.append("</\(openList)>") }; out.append("<\(tag)>"); openList = tag }
                out.append("<li>\(content)</li>")
                continue
            }
            if let openList { out.append("</\(openList)>") }
            openList = nil
            if let level = paragraph.headingLevel { out.append("<h\(level)>\(content)</h\(level)>") } else { out.append("<p>\(content)</p>") }
        }
        if let openList { out.append("</\(openList)>") }
        return out.joined(separator: "\n")
    }
}
