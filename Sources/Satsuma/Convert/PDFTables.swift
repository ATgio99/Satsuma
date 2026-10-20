import AppKit
import PDFKit

/// Table recognition for the PDF reflow, rebuilt from the original app's two detectors:
/// - ruled tables: a grid of stroked lines read from the content stream,
///   at least 80×30 pt; a word belongs to the cell holding 40 % of it;
/// - aligned tables: rows of short cells split by gaps wider than max(20, 2.5 × the median
///   word height), taller than 3 × that height. Cells longer than 34 characters break the run.
/// The first row is a header when its cells read as labels: ≤ 32 characters and ≤ 3 words.
/// In ruled tables a missing rule between two grid slots merges them, giving the row and column spans that
/// The original app's `SDCell` carries (`rowSpan`, `columnSpan`, `covered`).
enum PDFTableDetector {
    struct Word {
        var text: String
        var bounds: CGRect
        var isBold: Bool
    }

    /// A grid slot while a table is being built.
    struct Slot {
        var words: [Word] = []
        var rowSpan = 1
        var columnSpan = 1
        var covered = false
        var isBlank: Bool { words.isEmpty && !covered && rowSpan == 1 && columnSpan == 1 }
    }

    struct Table {
        var bounds: CGRect
        var rows: [[PDFReflow.TableCell]]
        var widths: [Double]
        var headers: Int
    }

    static func tables(on page: PDFPage) -> [Table] {
        let words = words(on: page)
        guard words.count >= 4 else { return [] }
        var found = ruledTables(rules: RuleScanner.rules(on: page), words: words)
        let free = words.filter { word in !found.contains { $0.bounds.insetBy(dx: -2, dy: -2).contains(word.center) } }
        found += alignedTables(words: free)
        return found
    }

    // MARK: Words with geometry

    /// Splits the page text into words and measures each with a selection. (`characterBounds(at:)` drifts by one
    /// character after every synthesized line break, so it can't be paired with `page.string` indices.)
    static func words(on page: PDFPage) -> [Word] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let text = string as NSString
        let separators = CharacterSet.whitespacesAndNewlines
        var words: [Word] = []
        var location = 0
        while location < text.length {
            let rest = NSRange(location: location, length: text.length - location)
            let found = text.rangeOfCharacter(from: separators.inverted, options: [], range: rest)
            guard found.location != NSNotFound else { break }
            let end = text.rangeOfCharacter(from: separators, options: [], range: NSRange(location: found.location, length: text.length - found.location))
            let range = NSRange(location: found.location, length: (end.location == NSNotFound ? text.length : end.location) - found.location)
            location = range.location + range.length
            guard let selection = page.selection(for: range) else { continue }
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
            var bold = false
            if let attributed = selection.attributedString, attributed.length > 0 {
                bold = true
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                    let name = (value as? NSFont)?.fontName.lowercased() ?? ""
                    if !(name.contains("bold") || name.contains("black") || name.contains("heavy") || name.contains("semibold")) { bold = false }
                }
            }
            words.append(Word(text: text.substring(with: range), bounds: bounds, isBold: bold))
        }
        return words
    }

    // MARK: Ruled tables

    static func ruledTables(rules: [Rule], words: [Word]) -> [Table] {
        let horizontal = rules.filter(\.isHorizontal), vertical = rules.filter { !$0.isHorizontal }
        guard horizontal.count >= 3, vertical.count >= 3 else { return [] }
        // Connected groups of crossing rules are candidate grids.
        var parent = Array(rules.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
        for i in rules.indices where rules[i].isHorizontal {
            for j in rules.indices where !rules[j].isHorizontal && rules[i].touches(rules[j]) {
                parent[root(i)] = root(j)
            }
        }
        let groups = Dictionary(grouping: rules.indices, by: root).values
        var tables: [Table] = []
        for group in groups {
            let members = group.map { rules[$0] }
            let ys = cluster(members.filter(\.isHorizontal).map(\.position)).sorted(by: >)
            let xs = cluster(members.filter { !$0.isHorizontal }.map(\.position)).sorted()
            guard ys.count >= 3, xs.count >= 3 else { continue }
            let bounds = CGRect(x: xs.first!, y: ys.last!, width: xs.last! - xs.first!, height: ys.first! - ys.last!)
            guard bounds.width >= 80, bounds.height >= 30 else { continue }
            let slots = ruledSlots(xs: xs, ys: ys, rules: members, words: words.filter { bounds.insetBy(dx: -1, dy: -1).contains($0.center) })
            let origins = slots.joined().filter { !$0.covered }
            let filled = origins.filter { !$0.words.isEmpty }.count
            // Charts draw grids too: a table has text in a good share of its cells.
            guard filled >= 2, Double(filled) >= Double(origins.count) * 0.3 else { continue }
            let widths = (0..<xs.count - 1).map { Double(xs[$0 + 1] - xs[$0]) }
            tables.append(makeTable(bounds: bounds, slots: slots, widths: widths))
        }
        return tables
    }

    /// Grid slots for rules at `xs` (left to right) and `ys` (top to bottom). Where the rule between two
    /// slots is missing they merge: first across (column span), then down (row span), like `SDCell`.
    static func ruledSlots(xs: [CGFloat], ys: [CGFloat], rules: [Rule], words: [Word]) -> [[Slot]] {
        let rowCount = ys.count - 1, columnCount = xs.count - 1
        func ruleBetweenColumns(at x: CGFloat, row: Int) -> Bool {
            let y = (ys[row] + ys[row + 1]) / 2
            return rules.contains { !$0.isHorizontal && abs($0.position - x) < 3 && $0.start - 2 <= y && y <= $0.end + 2 }
        }
        func ruleBetweenRows(at y: CGFloat, column: Int) -> Bool {
            let x = (xs[column] + xs[column + 1]) / 2
            return rules.contains { $0.isHorizontal && abs($0.position - y) < 3 && $0.start - 2 <= x && x <= $0.end + 2 }
        }
        var slots = Array(repeating: Array(repeating: Slot(), count: columnCount), count: rowCount)
        var origin = Array(repeating: Array(repeating: (0, 0), count: columnCount), count: rowCount)
        for row in 0..<rowCount {
            for column in 0..<columnCount where !slots[row][column].covered {
                var columnSpan = 1
                while column + columnSpan < columnCount, !slots[row][column + columnSpan].covered,
                      !ruleBetweenColumns(at: xs[column + columnSpan], row: row) { columnSpan += 1 }
                var rowSpan = 1
                while row + rowSpan < rowCount, (column..<column + columnSpan).allSatisfy({
                    !slots[row + rowSpan][$0].covered && !ruleBetweenRows(at: ys[row + rowSpan], column: $0)
                }) { rowSpan += 1 }
                slots[row][column].rowSpan = rowSpan
                slots[row][column].columnSpan = columnSpan
                for r in row..<row + rowSpan {
                    for c in column..<column + columnSpan {
                        origin[r][c] = (row, column)
                        if r != row || c != column { slots[r][c].covered = true }
                    }
                }
            }
        }
        for word in words {
            // The slot that holds the word's center, then the cell that spans it.
            guard let row = (0..<rowCount).first(where: { ys[$0 + 1] <= word.center.y && word.center.y <= ys[$0] }),
                  let column = (0..<columnCount).first(where: { xs[$0] <= word.center.x && word.center.x <= xs[$0 + 1] })
            else { continue }
            let (r, c) = origin[row][column]
            slots[r][c].words.append(word)
        }
        return slots
    }

    /// Merges positions closer than 3 pt (double borders, rules drawn twice).
    static func cluster(_ values: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values.sorted() {
            if let last = result.last, value - last < 3 { continue }
            result.append(value)
        }
        return result
    }

    // MARK: Aligned (borderless) tables

    struct Cell {
        var words: [Word]
        var bounds: CGRect { words.dropFirst().reduce(words[0].bounds) { $0.union($1.bounds) } }
        var text: String { words.map(\.text).joined(separator: " ") }
    }

    static func alignedTables(words: [Word]) -> [Table] {
        guard words.count >= 8 else { return [] }
        let heights = words.map(\.bounds.height).sorted()
        let height = heights[heights.count / 2]
        let threshold = max(20, height * 2.5)
        let textWidth = words.reduce(CGRect.null) { $0.union($1.bounds) }.width
        // Words as wide as a paragraph line or much taller than the text aren't table cells.
        let usable = words.filter { $0.bounds.width < textWidth * 0.65 && $0.bounds.height <= height * 1.3 }

        // Visual lines top to bottom, each split into cells at wide gaps.
        var lines: [[Word]] = []
        for word in usable.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let index = lines.lastIndex(where: { abs($0[0].bounds.midY - word.bounds.midY) < min($0[0].bounds.height, word.bounds.height) * 0.5 }) {
                lines[index].append(word)
            } else {
                lines.append([word])
            }
        }
        let rows: [[Cell]] = lines.map { line in
            var cells: [Cell] = []
            for word in line.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                if let last = cells.last, word.bounds.minX - last.bounds.maxX <= threshold {
                    cells[cells.count - 1].words.append(word)
                } else {
                    cells.append(Cell(words: [word]))
                }
            }
            return cells
        }

        var tables: [Table] = []
        var run: [[Cell]] = []
        func close() {
            defer { run = [] }
            guard run.count >= 3 else { return }
            let top = run[0].map(\.bounds.maxY).max()!, bottom = run.last!.map(\.bounds.minY).min()!
            guard top - bottom > height * 3 else { return }
            // Columns are the x-ranges of the cells, merged where they overlap.
            var columns: [ClosedRange<CGFloat>] = []
            for range in run.joined().map({ $0.bounds.minX...$0.bounds.maxX }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = columns.last, range.lowerBound <= last.upperBound + 2 {
                    columns[columns.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else {
                    columns.append(range)
                }
            }
            guard (2...8).contains(columns.count) else { return }
            var slots = Array(repeating: Array(repeating: Slot(), count: columns.count), count: run.count)
            for (row, line) in run.enumerated() {
                for cell in line {
                    let column = columns.firstIndex { $0.contains(cell.bounds.midX) } ?? 0
                    slots[row][column].words += cell.words
                }
            }
            // Boundaries halfway between columns, so the Word table keeps the PDF's proportions.
            var edges = [columns[0].lowerBound]
            for index in 1..<columns.count { edges.append((columns[index - 1].upperBound + columns[index].lowerBound) / 2) }
            edges.append(columns.last!.upperBound)
            let widths = (0..<columns.count).map { Double(edges[$0 + 1] - edges[$0]) + ($0 == columns.count - 1 ? 8 : 0) }
            let bounds = CGRect(x: edges.first!, y: bottom, width: edges.last! - edges.first!, height: top - bottom)
            tables.append(makeTable(bounds: bounds, slots: slots, widths: widths))
        }
        for (index, row) in rows.enumerated() {
            let isRow = row.count >= 2 && row.allSatisfy { $0.text.count <= 34 }
            if isRow, let previous = run.last, index > 0 {
                let gap = previous.map(\.bounds.minY).min()! - row.map(\.bounds.maxY).max()!
                if gap > height * 2.5 { close() }
            }
            if isRow { run.append(row) } else { close() }
        }
        close()
        return tables
    }

    // MARK: Shared

    static func makeTable(bounds: CGRect, slots: [[Slot]], widths: [Double]) -> Table {
        // Reading order inside a cell: line by line, left to right.
        func text(_ words: [Word]) -> String {
            words.sorted {
                abs($0.bounds.midY - $1.bounds.midY) < min($0.bounds.height, $1.bounds.height) * 0.5
                    ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY
            }.map(\.text).joined(separator: " ")
        }
        // Rows and columns that are blank everywhere (no text, nothing spanning them) are spacing, not cells.
        var rows = slots.filter { !$0.allSatisfy(\.isBlank) }
        var widths = widths
        for column in (0..<widths.count).reversed() where widths.count > 1 && rows.allSatisfy({ $0[column].isBlank }) {
            widths[column == 0 ? 1 : column - 1] += widths[column]
            widths.remove(at: column)
            for row in rows.indices { rows[row].remove(at: column) }
        }
        let cells = rows.map { row in
            row.map { PDFReflow.TableCell(text: $0.covered ? "" : text($0.words), rowSpan: $0.rowSpan,
                                          columnSpan: $0.columnSpan, covered: $0.covered) }
        }
        var headers = 0
        if cells.count > 1, let first = rows.first {
            let labels = cells[0].filter { !$0.covered && !$0.text.isEmpty }.map(\.text)
            let words = first.flatMap(\.words)
            let allBold = !words.isEmpty && words.allSatisfy(\.isBold)
            let short = !labels.isEmpty && labels.allSatisfy { label in
                label.count <= 32 && label.split(separator: " ").count <= 3 && label.contains(where: \.isLetter)
            }
            // A header cell spanning two rows (grouped headings) makes both rows the header.
            if allBold || short { headers = min(first.map(\.rowSpan).max() ?? 1, cells.count - 1) }
        }
        return Table(bounds: bounds, rows: cells, widths: widths, headers: headers)
    }
}

extension PDFTableDetector.Word {
    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
}

/// A straight horizontal or vertical rule drawn on the page.
struct Rule {
    var isHorizontal: Bool
    /// y for horizontal rules, x for vertical ones.
    var position: CGFloat
    var start: CGFloat
    var end: CGFloat

    func touches(_ other: Rule, tolerance: CGFloat = 2) -> Bool {
        other.start - tolerance <= position && position <= other.end + tolerance
            && start - tolerance <= other.position && other.position <= end + tolerance
    }
}

/// Reads stroked lines and hairline-thin filled rectangles from a page's content stream.
enum RuleScanner {
    final class State {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var point = CGPoint.zero
        var subpathStart = CGPoint.zero
        var segments: [(CGPoint, CGPoint)] = []
        var rects: [CGRect] = []
        var rules: [Rule] = []

        func add(_ a: CGPoint, _ b: CGPoint) {
            let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
            if dy <= 1, dx >= 6 { rules.append(Rule(isHorizontal: true, position: (a.y + b.y) / 2, start: min(a.x, b.x), end: max(a.x, b.x))) }
            if dx <= 1, dy >= 6 { rules.append(Rule(isHorizontal: false, position: (a.x + b.x) / 2, start: min(a.y, b.y), end: max(a.y, b.y))) }
        }

        func stroke() {
            for (a, b) in segments { add(a, b) }
            clear()
        }

        func fill() {
            // A filled rectangle at most 2.5 pt thick is a rule; tables are often drawn this way.
            for rect in rects {
                if rect.height <= 2.5, rect.width >= 6 { add(CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)) }
                else if rect.width <= 2.5, rect.height >= 6 { add(CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY)) }
            }
            clear()
        }

        func clear() { segments = []; rects = [] }
    }

    static func rules(on page: PDFPage) -> [Rule] {
        guard let cgPage = page.pageRef, let table = CGPDFOperatorTableCreate() else { return [] }
        let state = State()
        func with(_ info: UnsafeMutableRawPointer?) -> State { Unmanaged<State>.fromOpaque(info!).takeUnretainedValue() }
        func pop(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
            var values = [CGFloat](repeating: 0, count: count)
            for slot in (0..<count).reversed() { var value: CGPDFReal = 0; CGPDFScannerPopNumber(scanner, &value); values[slot] = value }
            return values
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in let s = with(info); s.stack.append(s.ctm) }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in let s = with(info); if let last = s.stack.popLast() { s.ctm = last } }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = with(info), v = pop(scanner, 6)
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            let s = with(info), v = pop(scanner, 2)
            s.point = CGPoint(x: v[0], y: v[1]).applying(s.ctm); s.subpathStart = s.point
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            let s = with(info), v = pop(scanner, 2)
            let next = CGPoint(x: v[0], y: v[1]).applying(s.ctm)
            s.segments.append((s.point, next)); s.point = next
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            let s = with(info); s.segments.append((s.point, s.subpathStart)); s.point = s.subpathStart
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let s = with(info), v = pop(scanner, 4)
            let rect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).applying(s.ctm).standardized
            s.rects.append(rect)
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            for i in 0..<4 { s.segments.append((corners[i], corners[(i + 1) % 4])) }
            s.point = corners[0]; s.subpathStart = corners[0]
        }
        for name in ["S", "s"] { CGPDFOperatorTableSetCallback(table, name) { _, info in with(info).stroke() } }
        for name in ["f", "F", "f*"] { CGPDFOperatorTableSetCallback(table, name) { _, info in with(info).fill() } }
        for name in ["B", "B*", "b", "b*"] { CGPDFOperatorTableSetCallback(table, name) { _, info in with(info).stroke() } }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in with(info).clear() }

        let contents = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(contents, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contents)
        CGPDFOperatorTableRelease(table)
        return state.rules
    }
}
