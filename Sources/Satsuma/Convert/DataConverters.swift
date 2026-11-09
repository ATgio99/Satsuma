import AppKit

/// Spreadsheets: CSV/TSV natively, XLSX and ODS through minimal readers/writers, XLS through Numbers.
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

    /// UTF-8, UTF-16 when a BOM says so, then the Windows and Latin-1 fallbacks; nil for bytes those would only turn into garbage.
    private static func decodeDelimited(_ data: Data) -> String? {
        var text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            // Mostly well-formed multi-byte sequences mean damaged UTF-8, which the 8-bit readings would garble throughout.
            let repaired = String(decoding: data, as: UTF8.self).unicodeScalars
            let damaged = repaired.filter { $0 == "\u{FFFD}" }.count
            guard repaired.filter({ !$0.isASCII }).count - damaged <= damaged else { return nil }
            text = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
        }
        // NULs are UTF-16 or UTF-32 without a usable BOM.
        return text?.unicodeScalars.contains("\0") == true ? nil : text
    }

    static func readRows(_ url: URL, format: ConversionFormat) async throws -> [[String]] {
        switch format {
        case .csv, .tsv:
            guard let data = try? Data(contentsOf: url), var text = decodeDelimited(data) else {
                throw ConversionError.sourceCannotBeRead
            }
            if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
            return parseDelimited(text, separator: format == .csv ? "," : "\t")
        case .xlsx:
            return try XLSX.read(url)
        case .ods:
            return try ODS.read(url)
        case .xls:
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
        if source == .xls && (target == .xlsx || target == .pdf) {
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
        case .ods: try ODS.write(rows: rows, to: output)
        case .xls:
            throw ConversionError.unsupportedPair(source, target)
        default:
            throw ConversionError.unsupportedPair(source, target)
        }
        return output
    }
}

/// Archives (`ArchiveConverter`): ZIP via ditto, TAR via bsdtar (which also reads RAR and GZIP), GZIP as a `.tar.gz` piped through gzip.
enum ArchiveConverter {
    /// With `macMetadata` false, tar leaves AppleDouble entries as plain files instead of restoring them (a malformed one is fatal).
    static func extract(_ url: URL, format: ConversionFormat, into folder: URL, macMetadata: Bool = true) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tarOptions = macMetadata ? [] : ["--no-mac-metadata"]
        switch format {
        case .zip: try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", url.path, folder.path])
        case .gzip where !isTarball(url):
            let name = url.deletingPathExtension().lastPathComponent
            let output = folder.appendingPathComponent(name.isEmpty ? "payload" : name)
            try await ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$0\" > \"$1\"", url.path, output.path])
            if holdsTar(output) { try await unpackTar(output, into: folder, options: tarOptions) }
        default: try await ProcessRunner.run("/usr/bin/tar", tarOptions + ["-xf", url.path, "-C", folder.path])
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard !contents.isEmpty else { throw ConversionError.encodingFailed("The source archive is empty.") }
    }

    /// Unpacks a tarball hidden in a plain `.gz`. It moves out of `folder` first, as an entry may share its name.
    private static func unpackTar(_ tar: URL, into folder: URL, options: [String]) async throws {
        let holding = try OutputNaming.temporaryDirectory(prefix: "Satsuma-archive-")
        defer { try? FileManager.default.removeItem(at: holding) }
        let moved = holding.appendingPathComponent("payload.tar")
        try FileManager.default.moveItem(at: tar, to: moved)
        try await ProcessRunner.run("/usr/bin/tar", options + ["-xf", moved.path, "-C", folder.path])
    }

    private static func isTarball(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
    }

    /// True for a file with the `ustar` magic at offset 257.
    private static func holdsTar(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 262), header.count == 262 else { return false }
        return header.suffix(5).elementsEqual("ustar".utf8)
    }

    /// The source's name without its archive suffix: `.tar.gz` or `.tgz`, otherwise the last extension.
    static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tgz"] where name.lowercased().hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `<stem>.<ext>` beside the source, then `<stem> 2.<ext>`. GZIP is always `.tar.gz`, even for one file.
    static func destination(for url: URL, target: ConversionFormat) -> URL {
        let folder = url.deletingLastPathComponent(), name = stem(of: url)
        let ext = target == .gzip ? "tar.gz" : target.fileExtension
        var candidate = folder.appendingPathComponent("\(name).\(ext)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    /// `-1`, `-6` or `-9` for zlib, from the Compression picker.
    private static func level(_ compression: CompressionLevel) -> String {
        switch compression {
        case .fast: return "1"
        case .balanced: return "6"
        case .maximum: return "9"
        }
    }

    /// Drops Finder residue that a source archive carried as ordinary files, so it stays out of the output.
    private static func removeFinderResidue(in folder: URL) async throws {
        // `find`, because FileManager's listings silently hide `._` files.
        let listing = try await ProcessRunner.run("/usr/bin/find", [folder.path, "(", "-name", "__MACOSX", "-o", "-name", "._*", ")", "-print0"])
        for item in listing.split(separator: "\0").map({ URL(fileURLWithPath: String($0)) })
        where item.lastPathComponent == "__MACOSX" || isAppleDouble(item) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// A `._name` sidecar: a file with the AppleDouble magic. The name alone proves nothing, as a user may have a `._git` too.
    private static func isAppleDouble(_ url: URL) -> Bool {
        guard url.lastPathComponent.hasPrefix("._"), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x00, 0x05, 0x16, 0x07])
    }

    static func convert(_ url: URL, from source: ConversionFormat, to target: ConversionFormat,
                        options: ConversionOptions = ConversionOptions()) async throws -> URL {
        let work = try OutputNaming.temporaryDirectory(prefix: "Satsuma-archive-")
        defer { try? FileManager.default.removeItem(at: work) }
        let contents = work.appendingPathComponent("contents")
        try await extract(url, format: source, into: contents, macMetadata: false)
        try await removeFinderResidue(in: contents)
        guard !((try? FileManager.default.contentsOfDirectory(atPath: contents.path)) ?? []).isEmpty else {
            throw ConversionError.encodingFailed("The source archive is empty.")
        }
        if target == .gzip { return try await packGzip(contents, work: work, source: url, options: options) }
        let output = destination(for: url, target: target)
        switch target {
        // Entries at the archive's root, no wrapping folder. No resource forks or tar AppleDouble: macOS tags extracted files, which would add junk beside every entry.
        case .zip: try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--zlibCompressionLevel", level(options.compression), contents.path, output.path])
        case .tar: try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "-cf", output.path, "-C", contents.path, "."])
        default: throw ConversionError.unsupportedPair(source, target)
        }
        return output
    }

    /// `.tar.gz` of the extracted entries (no wrapping folder), built in `work` and moved beside the source when complete.
    private static func packGzip(_ root: URL, work: URL, source: URL, options: ConversionOptions) async throws -> URL {
        let tar = work.appendingPathComponent("payload.tar"), gzipped = work.appendingPathComponent("output.tar.gz")
        try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "-cf", tar.path, "-C", root.path, "."])
        // `-n` keeps the temporary name "payload.tar" out of the gzip header.
        try await ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/gzip -\(level(options.compression)) -n -c \"$0\" > \"$1\"", tar.path, gzipped.path])
        let output = destination(for: source, target: .gzip)
        try FileManager.default.moveItem(at: gzipped, to: output)
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
