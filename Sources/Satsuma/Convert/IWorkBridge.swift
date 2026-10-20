import Foundation

/// Uses the installed iWork apps for formats only they can read or write
/// (the original app instead bundles a JavaScript Pages writer and a Java/Apache POI runtime).
enum IWorkBridge {
    private static func runAppleScript(_ source: String) async throws {
        try await ProcessRunner.run("/usr/bin/osascript", ["-e", source])
    }

    private static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Opens `source` in `app`, runs `body` on `theDoc`, then closes it without saving.
    /// iWork imports foreign files (.docx, .xls, .ppt…) asynchronously: `open` then returns an import handle
    /// ("export id …"), not a document, and commands sent to it fail with -1708. So the script waits for the
    /// new document to appear instead of using `open`'s result.
    private static func withOpenedDocument(app: String, source: URL, output: URL, body: String) -> String {
        """
        set src to POSIX file \(quoted(source.path))
        set dst to POSIX file \(quoted(output.path))
        with timeout of 600 seconds
            tell application "\(app)"
                set known to {}
                try
                    set known to id of every document
                end try
                open src
                set theDoc to missing value
                repeat 480 times
                    try
                        repeat with candidate in (every document)
                            if known does not contain (id of candidate) then
                                set theDoc to contents of candidate
                                exit repeat
                            end if
                        end repeat
                    end try
                    if theDoc is not missing value then exit repeat
                    delay 0.25
                end repeat
                if theDoc is missing value then error "\(app) didn’t finish opening the document."
                \(body)
                close theDoc saving no
            end tell
        end timeout
        """
    }

    /// Opens `source` in `app` and exports it with the given AppleScript export format.
    private static func export(app: String, source: URL, to output: URL, as format: String, extraProperties: String = "") async throws {
        try await runAppleScript(withOpenedDocument(app: app, source: source, output: output,
                                                    body: "export theDoc to dst as \(format)\(extraProperties)"))
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.outputMissing }
    }

    static func exportPagesToDOCX(_ source: URL) async throws -> URL {
        guard ToolLocator.hasPages else { throw ConversionError.missingTool("Pages") }
        let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-pages-")
        let output = folder.appendingPathComponent("document.docx")
        try await export(app: "Pages", source: source, to: output, as: "Microsoft Word")
        return output
    }

    static func convertToPages(_ docx: URL, beside source: URL) async throws -> URL {
        guard ToolLocator.hasPages else { throw ConversionError.encodingFailed("The native Pages writer is unavailable.") }
        let output = OutputNaming.destination(for: source, extension: "pages")
        try await runAppleScript(withOpenedDocument(app: "Pages", source: docx, output: output, body: "save theDoc in dst"))
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.outputMissing }
        return output
    }

    static func keynoteToPDF(_ source: URL, output: URL) async throws {
        guard ToolLocator.hasKeynote else { throw ConversionError.missingTool("Keynote") }
        try await export(app: "Keynote", source: source, to: output, as: "PDF")
    }

    static func numbersExport(_ source: URL, output: URL, format: ConversionFormat) async throws {
        guard ToolLocator.hasNumbers else { throw ConversionError.missingTool("Numbers") }
        let appleFormat: String
        switch format {
        case .xlsx: appleFormat = "Microsoft Excel"
        case .csv: appleFormat = "CSV"
        case .pdf: appleFormat = "PDF"
        default: throw ConversionError.unsupportedPair(.xlsx, format)
        }
        try await export(app: "Numbers", source: source, to: output, as: appleFormat)
    }
}
