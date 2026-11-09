import AVFoundation
import AppKit

/// ffmpeg work behind the video and audio tools.
enum MediaTools {
    static func ffmpegPath() throws -> String {
        guard let path = ToolLocator.ffmpeg else { throw ConversionError.missingTool("ffmpeg") }
        return path
    }

    @discardableResult
    static func ffmpeg(_ arguments: [String], duration: Double? = nil, progress: ((Double) -> Void)? = nil) async throws -> String {
        let base = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        let extra = progress != nil ? ["-progress", "pipe:1", "-nostats"] : []
        return try await ProcessRunner.run(try ffmpegPath(), base + extra + arguments) { line in
            guard let progress, let duration, duration > 0, line.hasPrefix("out_time_us="),
                  let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(1, micros / 1_000_000 / duration))
        }
    }

    static func videoCodecArguments(crf: Int = 20) -> [String] {
        ["-c:v", "libx264", "-preset", "medium", "-crf", "\(crf)", "-pix_fmt", "yuv420p"]
    }

    static func outputExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "mkv", "m4v"].contains(ext) ? ext : "mp4"
    }

    // MARK: Compress

    static func compressVideo(_ url: URL, plan: ImageProcessing.CompressionPlan, progress: @escaping (Double) -> Void) async throws -> URL {
        let facts = await MediaFacts.load(url)
        let output = OutputNaming.destination(for: url, extension: "mp4", suffix: " compressed")
        var arguments = ["-i", url.path]
        if let target = plan.targetBytes {
            let audioBits = facts.hasAudio ? 96_000.0 : 0
            let totalBits = Double(target) * 8 * 0.96
            let videoBits = totalBits / max(facts.duration, 0.1) - audioBits
            guard videoBits > 50_000 else {
                throw ConversionError.encodingFailed("The target is too small for this duration. Choose a larger size.")
            }
            arguments += ["-c:v", "libx264", "-b:v", "\(Int(videoBits))", "-maxrate", "\(Int(videoBits * 1.2))", "-bufsize", "\(Int(videoBits * 2))",
                          "-pix_fmt", "yuv420p"]
        } else {
            arguments += videoCodecArguments(crf: plan.strong ? 31 : 26)
        }
        var scaling = ConversionOptions()
        scaling.videoMaxHeight = plan.strong && plan.targetBytes == nil ? 1080 : 0
        arguments += MediaConverter.evenScaleFilter(scaling)
        arguments += facts.hasAudio ? ["-c:a", "aac", "-b:a", plan.strong ? "96k" : "128k"] : ["-an"]
        arguments += ["-movflags", "+faststart", output.path]
        try await ffmpeg(arguments, duration: facts.duration, progress: progress)
        if plan.targetBytes == nil, let original = ToolFormat.fileSize(url), let size = ToolFormat.fileSize(output), size >= original {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.encodingFailed("Compressed output would exceed the original or target file size.")
        }
        return output
    }

    static func compressAudio(_ url: URL, plan: ImageProcessing.CompressionPlan) async throws -> URL {
        let facts = await MediaFacts.load(url)
        var bitrate = plan.strong ? 64_000.0 : 128_000.0
        if let target = plan.targetBytes { bitrate = max(24_000, Double(target) * 8 * 0.97 / max(facts.duration, 0.1)) }
        let output = OutputNaming.destination(for: url, extension: "m4a", suffix: " compressed")
        try await ffmpeg(["-i", url.path, "-vn", "-c:a", "aac", "-b:a", "\(Int(bitrate))", output.path])
        return output
    }

    // MARK: Video

    static func trim(_ url: URL, start: Double, end: Double, audioOnly: Bool, progress: @escaping (Double) -> Void) async throws -> URL {
        let ext = audioOnly ? url.pathExtension : outputExtension(for: url)
        let output = OutputNaming.destination(for: url, extension: ext, suffix: " trimmed")
        var arguments = ["-ss", String(format: "%.3f", start), "-to", String(format: "%.3f", end), "-i", url.path]
        // -ss before -i with re-encode keeps frame accuracy.
        arguments = ["-i", url.path, "-ss", String(format: "%.3f", start), "-to", String(format: "%.3f", end)]
        if audioOnly {
            arguments += ["-vn"]
        } else {
            arguments += videoCodecArguments(crf: 18) + ["-vf", MediaConverter.evenSize, "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        }
        try await ffmpeg(arguments + [output.path], duration: end - start, progress: progress)
        return output
    }

    static func crop(_ url: URL, rect: NormalizedRect, outputSize: CGSize?, progress: @escaping (Double) -> Void) async throws -> URL {
        let facts = await MediaFacts.load(url)
        let w = Int((rect.width * facts.size.width / 2).rounded()) * 2
        let h = Int((rect.height * facts.size.height / 2).rounded()) * 2
        let x = Int(rect.x * facts.size.width), y = Int(rect.y * facts.size.height)
        guard w >= 2, h >= 2 else { throw ConversionError.invalidFileToolOptions("The crop must be at least 2 pixels wide and tall.") }
        var filter = "crop=\(w):\(h):\(x):\(y)"
        if let outputSize, Int(outputSize.width) != w || Int(outputSize.height) != h {
            filter += ",scale=\(Int(outputSize.width) / 2 * 2):\(Int(outputSize.height) / 2 * 2)"
        }
        let output = OutputNaming.destination(for: url, extension: outputExtension(for: url), suffix: " cropped")
        // Keep the original audio.
        try await ffmpeg(["-i", url.path, "-vf", filter] + videoCodecArguments(crf: 18) + ["-c:a", "copy", output.path],
                         duration: facts.duration, progress: progress)
        return output
    }

    static func changeSpeed(_ url: URL, speed: Double, progress: @escaping (Double) -> Void) async throws -> URL {
        let facts = await MediaFacts.load(url)
        let output = OutputNaming.destination(for: url, extension: outputExtension(for: url), suffix: " \(speedLabel(speed))")
        var arguments = ["-i", url.path, "-filter:v", "setpts=PTS/\(speed),\(MediaConverter.evenSize)"]
        if facts.hasAudio {
            // atempo accepts 0.5…2 per stage; chain stages to preserve pitch.
            var stages: [String] = []
            var remaining = speed
            while remaining > 2 { stages.append("atempo=2"); remaining /= 2 }
            while remaining < 0.5 { stages.append("atempo=0.5"); remaining /= 0.5 }
            stages.append("atempo=\(remaining)")
            arguments += ["-filter:a", stages.joined(separator: ","), "-c:a", "aac", "-b:a", "192k"]
        } else {
            arguments += ["-an"]
        }
        try await ffmpeg(arguments + videoCodecArguments(crf: 18) + [output.path], duration: facts.duration / speed, progress: progress)
        return output
    }

    static func speedLabel(_ speed: Double) -> String { speed == speed.rounded() ? "\(Int(speed))x" : "\(speed)x" }

    /// "Frame %03d - %.3fs.png" in a folder beside the video.
    static func snapshots(_ url: URL, times: [Double]) async throws -> [URL] {
        guard !times.isEmpty else { throw ConversionError.invalidFileToolOptions("Add a frame to save.") }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let folder = OutputNaming.unique(url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " frames"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (index, time) in times.sorted().enumerated() {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let name = String(format: "Frame %03d - %.3fs.png", index + 1, time)
            let output = folder.appendingPathComponent(name)
            try ImageConverter.write([image], properties: [nil], to: output, format: .png, options: ConversionOptions())
            outputs.append(output)
        }
        return [folder]
    }

    /// Splits into clips at the given points, all inside one folder.
    static func split(_ url: URL, points: [Double], duration: Double, progress: @escaping (Double) -> Void) async throws -> URL {
        let cuts = ([0] + points.sorted() + [duration])
        guard cuts.count >= 3 else { throw ConversionError.invalidFileToolOptions("Add split points inside the video, at least 0.05 seconds from either end.") }
        let folder = OutputNaming.unique(url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " clips"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = outputExtension(for: url)
        for index in 0..<(cuts.count - 1) {
            let output = folder.appendingPathComponent(String(format: "%@ %02d.%@", url.deletingPathExtension().lastPathComponent, index + 1, ext))
            try await ffmpeg(["-i", url.path, "-ss", String(format: "%.3f", cuts[index]), "-to", String(format: "%.3f", cuts[index + 1])]
                             + videoCodecArguments(crf: 18) + ["-vf", MediaConverter.evenSize, "-c:a", "aac", "-b:a", "192k", output.path])
            progress(Double(index + 1) / Double(cuts.count - 1))
        }
        return folder
    }

    /// Boxes with optional time ranges; solid colour or blur.
    static func redactVideo(_ url: URL, rects: [NormalizedRect], blur: Bool, progress: @escaping (Double) -> Void) async throws -> URL {
        let facts = await MediaFacts.load(url)
        guard !rects.isEmpty else { throw ConversionError.invalidFileToolOptions("Draw a rectangle over the area to hide.") }
        let width = facts.size.width, height = facts.size.height
        func box(_ r: NormalizedRect) -> (Int, Int, Int, Int) {
            (Int(r.x * width), Int(r.y * height), max(2, Int(r.width * width)), max(2, Int(r.height * height)))
        }
        func enable(_ r: NormalizedRect) -> String {
            guard let range = r.timeRange else { return "" }
            return ":enable='between(t,\(String(format: "%.3f", range.lowerBound)),\(String(format: "%.3f", range.upperBound)))'"
        }
        var graph: String
        if blur {
            var parts = ["[0:v]null[v0]"]
            for (index, r) in rects.enumerated() {
                let (x, y, w, h) = box(r)
                // Gaussian blur scales with the box and has no radius limit (boxblur fails on small boxes).
                let sigma = max(4, min(w, h) / 6)
                parts.append("[0:v]crop=\(w):\(h):\(x):\(y),gblur=sigma=\(sigma):steps=3[b\(index)]")
                parts.append("[v\(index)][b\(index)]overlay=\(x):\(y)\(enable(r))[v\(index + 1)]")
            }
            graph = parts.joined(separator: ";")
            graph += ";[v\(rects.count)]\(MediaConverter.evenSize)[out]"
        } else {
            let boxes = rects.map { r -> String in
                let (x, y, w, h) = box(r)
                let hex = String(format: "0x%02X%02X%02X", Int(r.color.red * 255), Int(r.color.green * 255), Int(r.color.blue * 255))
                return "drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=\(hex):t=fill\(enable(r))"
            }
            graph = "[0:v]" + boxes.joined(separator: ",") + ",\(MediaConverter.evenSize)[out]"
        }
        let output = OutputNaming.destination(for: url, extension: outputExtension(for: url), suffix: " redacted")
        try await ffmpeg(["-i", url.path, "-filter_complex", graph, "-map", "[out]", "-map", "0:a?"]
                         + videoCodecArguments(crf: 18) + ["-c:a", "copy", output.path], duration: facts.duration, progress: progress)
        return output
    }

    // MARK: Audio

    static func normalize(_ url: URL, loudness: Double, range: Double, truePeak: Double, progress: @escaping (Double) -> Void) async throws -> URL {
        let facts = await MediaFacts.load(url)
        let ext = facts.hasVideo ? outputExtension(for: url) : url.pathExtension
        let output = OutputNaming.destination(for: url, extension: ext, suffix: " normalized")
        var arguments = ["-i", url.path, "-af", "loudnorm=I=\(loudness):LRA=\(range):TP=\(truePeak)", "-ar", "48000"]
        if facts.hasVideo { arguments += ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"] }
        try await ffmpeg(arguments + [output.path], duration: facts.duration, progress: progress)
        return output
    }

    enum VisualizerShape: String, CaseIterable, Identifiable {
        case landscape = "Landscape · 16:9", portrait = "Portrait · 9:16", square = "Square · 1:1"
        var id: String { rawValue }
        var size: (Int, Int) { switch self { case .landscape: return (1920, 1080); case .portrait: return (1080, 1920); case .square: return (1080, 1080) } }
    }

    static func visualize(_ url: URL, waveform: Bool, image: URL?, shape: VisualizerShape, progress: @escaping (Double) -> Void) async throws -> URL {
        let facts = await MediaFacts.load(url)
        let (w, h) = shape.size
        let output = OutputNaming.destination(for: url, extension: "mp4", suffix: " visualizer")
        var arguments: [String]
        if waveform {
            let color = "0xFF5200"
            arguments = ["-i", url.path, "-filter_complex",
                         "[0:a]aformat=channel_layouts=mono,showwaves=s=\(w)x\(h / 2):mode=cline:rate=30:colors=\(color),pad=\(w):\(h):0:\(h / 4):black,format=yuv420p[v]",
                         "-map", "[v]", "-map", "0:a"]
        } else {
            guard let image else { throw ConversionError.invalidFileToolOptions("Choose an image for the visualization.") }
            arguments = ["-loop", "1", "-i", image.path, "-i", url.path, "-filter_complex",
                         "[0:v]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,format=yuv420p[v]",
                         "-map", "[v]", "-map", "1:a", "-shortest", "-r", "30"]
        }
        arguments += videoCodecArguments(crf: 20) + ["-c:a", "aac", "-b:a", "192k", output.path]
        try await ffmpeg(arguments, duration: facts.duration, progress: progress)
        return output
    }

    /// Finds the first and last non-silent instants (`autoTrimSilence`).
    static func detectSilence(_ url: URL, thresholdDB: Double, duration: Double) async -> (Double, Double)? {
        guard let ffmpeg = ToolLocator.ffmpeg else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-hide_banner", "-nostdin", "-i", url.path, "-af", "silencedetect=noise=\(thresholdDB)dB:d=0.1", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        func values(_ key: String) -> [Double] {
            text.components(separatedBy: "\n").compactMap { line in
                guard let range = line.range(of: key) else { return nil }
                return Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            }
        }
        let starts = values("silence_start:"), ends = values("silence_end:")
        var start = 0.0, end = duration
        if let firstStart = starts.first, firstStart < 0.05, let firstEnd = ends.first { start = firstEnd }
        if let lastStart = starts.last, ends.count < starts.count || (ends.last ?? 0) >= duration - 0.05 { end = lastStart }
        guard end - start > 0.05 else { return nil }
        return (start, end)
    }

    static func channels(_ url: URL, stereo: Bool, left: Double, right: Double) async throws -> URL {
        let facts = await MediaFacts.load(url)
        let ext = facts.hasVideo ? outputExtension(for: url) : url.pathExtension
        let output = OutputNaming.destination(for: url, extension: ext, suffix: stereo ? " stereo" : " mono")
        let source = facts.audioChannels >= 2 ? ("c0", "c1") : ("c0", "c0")
        let filter = stereo
            ? "pan=stereo|c0=\(left)*\(source.0)|c1=\(right)*\(source.1)"
            : "pan=mono|c0=\(left * 0.5)*\(source.0)+\(right * 0.5)*\(source.1)"
        var arguments = ["-i", url.path, "-af", filter]
        if facts.hasVideo { arguments += ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"] }
        try await ffmpeg(arguments + [output.path])
        return output
    }

    /// Mutes each range and mixes in a 1 kHz tone (`AudioBleepTimeline`).
    static func bleep(_ url: URL, ranges: [ClosedRange<Double>], progress: @escaping (Double) -> Void) async throws -> URL {
        guard !ranges.isEmpty else { throw ConversionError.invalidFileToolOptions("Add at least one bleep range.") }
        let facts = await MediaFacts.load(url)
        let between = ranges.map { "between(t,\(String(format: "%.3f", $0.lowerBound)),\(String(format: "%.3f", $0.upperBound)))" }.joined(separator: "+")
        let graph = "[0:a]volume=0:enable='\(between)'[muted];" +
            "sine=f=1000:sample_rate=48000:d=\(facts.duration),volume=0.25,volume=0:enable='not(\(between))'[tone];" +
            "[muted][tone]amix=inputs=2:duration=first:normalize=0[a]"
        let ext = facts.hasVideo ? outputExtension(for: url) : url.pathExtension
        let output = OutputNaming.destination(for: url, extension: ext, suffix: " bleeped")
        var arguments = ["-i", url.path, "-filter_complex", graph, "-map", "[a]"]
        if facts.hasVideo { arguments += ["-map", "0:v", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k"] }
        try await ffmpeg(arguments + [output.path], duration: facts.duration, progress: progress)
        return output
    }

    /// Renders a temporary preview file (bleep, channels, normalize) for the Play buttons.
    static func preview(_ url: URL, filter: String, complex: Bool = false) async -> URL? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-preview-\(UUID().uuidString).m4a")
        let arguments = complex ? ["-i", url.path, "-filter_complex", filter, "-map", "[a]", "-c:a", "aac", output.path]
                                : ["-i", url.path, "-vn", "-af", filter, "-c:a", "aac", output.path]
        return (try? await ffmpeg(arguments)) != nil ? output : nil
    }
}
