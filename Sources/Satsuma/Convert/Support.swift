import AppKit
import zlib

/// `ConversionError`, with the original's user-facing messages.
enum ConversionError: LocalizedError {
    case unsupportedPair(ConversionFormat, ConversionFormat)
    case missingTool(String)
    case processFailed(String)
    case encodingFailed(String)
    case fileToolUnavailable(String)
    case invalidFileToolOptions(String)
    case unsupportedSource
    case outputMissing
    case sourceCannotBeRead

    var errorDescription: String? {
        switch self {
        case .unsupportedPair(let source, let target): return "Conversion from \(source.title) to \(target.title) is unavailable."
        case .missingTool(let name): return "\(name) is required for this conversion."
        case .processFailed(let detail): return detail.isEmpty ? "The conversion process failed." : detail
        case .encodingFailed(let detail): return detail
        case .fileToolUnavailable(let name): return "\(name) is unavailable for this file type."
        case .invalidFileToolOptions(let detail): return detail
        case .unsupportedSource: return "This file type is not supported."
        case .outputMissing: return "The converter finished without creating an output file."
        case .sourceCannotBeRead: return "The source file could not be read."
        }
    }
}

/// Finds helper executables. The original app bundles ffmpeg/cwebp; Satsuma uses the ones installed on the Mac.
enum ToolLocator {
    static func path(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ffmpeg: String? { path("ffmpeg") }
    static var ffprobe: String? { path("ffprobe") }

    static func appInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var hasPages: Bool { appInstalled(bundleID: "com.apple.iWork.Pages") }
    static var hasKeynote: Bool { appInstalled(bundleID: "com.apple.iWork.Keynote") }
    static var hasNumbers: Bool { appInstalled(bundleID: "com.apple.iWork.Numbers") }
}

/// Runs a command-line tool off the main thread.
enum ProcessRunner {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil,
                    onOutputLine: ((String) -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let errorBuffer = OutputBuffer()
            let outputBuffer = OutputBuffer()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                errorBuffer.append(handle.availableData)
            }
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                outputBuffer.append(chunk)
                if let onOutputLine, let text = String(data: chunk, encoding: .utf8) {
                    text.split(separator: "\n").forEach { onOutputLine(String($0)) }
                }
            }
            process.terminationHandler = { process in
                stderr.fileHandleForReading.readabilityHandler = nil
                stdout.fileHandleForReading.readabilityHandler = nil
                errorBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                outputBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let errorText = errorBuffer.text
                let outputText = outputBuffer.text
                if process.terminationStatus == 0 {
                    continuation.resume(returning: outputText)
                } else {
                    let tail = errorText.split(separator: "\n").suffix(3).joined(separator: "\n")
                    continuation.resume(throwing: ConversionError.processFailed(tail))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Thread-safe byte buffer for process output.
final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Results are saved beside the originals, never overwriting an existing file.
enum OutputNaming {
    static func destination(for source: URL, extension ext: String, suffix: String = "") -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        return unique(folder.appendingPathComponent(base).appendingPathExtension(ext))
    }

    static func unique(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    static func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Minimal ZIP writer (stored entries) used for DOCX, EPUB, PPTX and XLSX packages.
struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(_ path: String, _ contents: Data) {
        let name = Data(path.utf8)
        let crc = contents.withUnsafeBytes { buffer -> UInt32 in
            UInt32(crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
        let offset = UInt32(data.count)
        var local = Data()
        local.append(le32: 0x04034b50); local.append(le16: 20); local.append(le16: 0x0800); local.append(le16: 0)
        local.append(le16: 0); local.append(le16: 0x21)
        local.append(le32: crc); local.append(le32: UInt32(contents.count)); local.append(le32: UInt32(contents.count))
        local.append(le16: UInt16(name.count)); local.append(le16: 0)
        data.append(local); data.append(name); data.append(contents)

        central.append(le32: 0x02014b50); central.append(le16: 0x031e); central.append(le16: 20); central.append(le16: 0x0800)
        central.append(le16: 0); central.append(le16: 0); central.append(le16: 0x21)
        central.append(le32: crc); central.append(le32: UInt32(contents.count)); central.append(le32: UInt32(contents.count))
        central.append(le16: UInt16(name.count)); central.append(le16: 0); central.append(le16: 0)
        central.append(le16: 0); central.append(le16: 0); central.append(le32: 0o100644 << 16)
        central.append(le32: offset); central.append(name)
        count += 1
    }

    mutating func add(_ path: String, _ text: String) { add(path, Data(text.utf8)) }

    func finish() -> Data {
        var out = data
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x06054b50); out.append(le16: 0); out.append(le16: 0)
        out.append(le16: count); out.append(le16: count)
        out.append(le32: UInt32(central.count)); out.append(le32: centralOffset); out.append(le16: 0)
        return out
    }
}

extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}

extension String {
    var xmlEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for character in self {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20, scalar != "\n", scalar != "\t" { continue }
                out.append(character)
            }
        }
        return out
    }
}
