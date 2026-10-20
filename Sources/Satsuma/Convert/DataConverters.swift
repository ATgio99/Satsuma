import AppKit

/// Spreadsheets: CSV/TSV natively, XLSX through a minimal OOXML reader/writer, XLS/ODS through Numbers.
enum SpreadsheetConverter {
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { field.append(character) }
            } else if character == "\"" && field.isEmpty {
                inQuotes = true
            } else if character == separator {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func serialize(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in
            row.map { value in
                let needsQuotes = value.contains(separator) || value.contains("\"") || value.contains("\n")
                return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: String(separator))
        }.joined(separator: "\n") + "\n"
    }

    static func readRows(_ url: URL, format: ConversionFormat) async throws -> [[String]] {
        switch format {
        case .csv, .tsv:
            guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else {
                throw ConversionError.sourceCannotBeRead
            }
            return parseDelimited(text, separator: format == .csv ? "," : "\t")
        case .xlsx:
            return try XLSX.read(url)
        case .xls, .ods:
            let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-sheet-")
            defer { try? FileManager.default.removeItem(at: folder) }
            let csv = folder.appendingPathComponent("sheet.csv")
            try await IWorkBridge.numbersExport(url, output: csv, format: .csv)
            // Numbers writes a folder of CSVs when the document has several tables.
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: csv.path, isDirectory: &isDirectory)
            let file = isDirectory.boolValue
                ? (try FileManager.default.contentsOfDirectory(at: csv, includingPropertiesForKeys: nil)).first { $0.pathExtension == "csv" }
                : csv
            guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { throw ConversionError.sourceCannotBeRead }
            return parseDelimited(text, separator: ",")
        default:
            throw ConversionError.unsupportedSource
        }
    }

    @MainActor
    static func convert(_ url: URL, from source: ConversionFormat, to target: ConversionFormat) async throws -> URL {
        let output = OutputNaming.destination(for: url, extension: target.fileExtension)
        if (source == .xls || source == .ods) && (target == .xlsx || target == .pdf) {
            try await IWorkBridge.numbersExport(url, output: output, format: target)
            return output
        }
        let rows = try await readRows(url, format: source)
        guard !rows.isEmpty else { throw ConversionError.encodingFailed("The spreadsheet is empty or exceeds the 128 MB conversion limit.") }
        switch target {
        case .csv: try serialize(rows, separator: ",").write(to: output, atomically: true, encoding: .utf8)
        case .tsv: try serialize(rows, separator: "\t").write(to: output, atomically: true, encoding: .utf8)
        case .xlsx: try XLSX.write(rows: rows, to: output)
        case .pdf:
            let html = "<table>" + rows.enumerated().map { index, row in
                let tag = index == 0 ? "th" : "td"
                return "<tr>" + row.map { "<\(tag)>\($0.xmlEscaped)</\(tag)>" }.joined() + "</tr>"
            }.joined() + "</table>"
            let page = "<!doctype html><html><head><meta charset=\"utf-8\"><style>body{font:10pt Helvetica}table{border-collapse:collapse}td,th{border:1px solid #aaa;padding:3px}th{background:#eee}</style></head><body>\(html)</body></html>"
            try DocumentIO.renderPDF(try DocumentIO.fromHTML(page), to: output)
        case .ods, .xls:
            throw ConversionError.unsupportedPair(source, target)
        default:
            throw ConversionError.unsupportedPair(source, target)
        }
        return output
    }
}

/// Archives (`ArchiveConverter`): ZIP via ditto, TAR via bsdtar (which also reads RAR and GZIP).
enum ArchiveConverter {
    static func extract(_ url: URL, format: ConversionFormat, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch format {
        case .zip: try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", url.path, folder.path])
        case .gzip where !url.lastPathComponent.lowercased().contains(".tar"):
            let output = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            try await ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$0\" > \"$1\"", url.path, output.path])
        default: try await ProcessRunner.run("/usr/bin/tar", ["-xf", url.path, "-C", folder.path])
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard !contents.isEmpty else { throw ConversionError.encodingFailed("The source archive is empty.") }
    }

    static func convert(_ url: URL, from source: ConversionFormat, to target: ConversionFormat) async throws -> URL {
        let output = OutputNaming.destination(for: url, extension: target.fileExtension)
        let work = try OutputNaming.temporaryDirectory(prefix: "Satsuma-archive-")
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent(url.deletingPathExtension().deletingPathExtension().lastPathComponent)
        try await extract(url, format: source, into: root)
        switch target {
        case .zip: try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, output.path])
        case .tar: try await ProcessRunner.run("/usr/bin/tar", ["-cf", output.path, "-C", work.path, root.lastPathComponent])
        default: throw ConversionError.unsupportedPair(source, target)
        }
        return output
    }

    /// The Extract Archive tool: unpack beside the original.
    static func extractBeside(_ url: URL) async throws -> URL {
        guard let format = ConversionFormat.detect(url) else { throw ConversionError.unsupportedSource }
        let base = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        let folder = OutputNaming.unique(url.deletingLastPathComponent().appendingPathComponent(base))
        try await extract(url, format: format, into: folder)
        return folder
    }
}

/// SRT ↔ WebVTT (`SubtitleConverter`).
enum SubtitleConverter {
    struct Cue { var start: String; var end: String; var text: [String] }

    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let end = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            cues.append(Cue(start: parts[0].trimmingCharacters(in: .whitespaces), end: end, text: Array(lines[(timing + 1)...])))
        }
        return cues
    }

    static func convert(_ url: URL, to target: ConversionFormat) throws -> URL {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ConversionError.encodingFailed("The subtitle file is not valid UTF-8.")
        }
        let cues = parse(text)
        guard !cues.isEmpty else { throw ConversionError.encodingFailed("No valid subtitle cues were found.") }
        let output = OutputNaming.destination(for: url, extension: target.fileExtension)
        if target == .txt {
            // Subtitles → TXT: the spoken lines only, without numbers or timings.
            try cues.map { $0.text.joined(separator: " ") }.joined(separator: "\n").appending("\n")
                .write(to: output, atomically: true, encoding: .utf8)
            return output
        }
        var result = target == .vtt ? "WEBVTT\n\n" : ""
        for (index, cue) in cues.enumerated() {
            let start = target == .vtt ? cue.start.replacingOccurrences(of: ",", with: ".") : srtTime(cue.start)
            let end = target == .vtt ? cue.end.replacingOccurrences(of: ",", with: ".") : srtTime(cue.end)
            if target == .srt { result += "\(index + 1)\n" }
            result += "\(start) --> \(end)\n" + cue.text.joined(separator: "\n") + "\n\n"
        }
        try result.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func srtTime(_ time: String) -> String {
        var value = time.replacingOccurrences(of: ".", with: ",")
        if value.filter({ $0 == ":" }).count == 1 { value = "00:" + value }
        return value
    }
}
