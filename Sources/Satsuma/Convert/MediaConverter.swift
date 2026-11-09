import Foundation

/// Audio, video and GIF conversions through ffmpeg (the original app ships its own ffmpeg in Resources/Tools).
enum MediaConverter {
    static var isAvailable: Bool { ToolLocator.ffmpeg != nil }

    static func duration(of url: URL) async -> Double? {
        guard let ffprobe = ToolLocator.ffprobe,
              let text = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                                                "-of", "default=nw=1:nk=1", url.path])
        else { return nil }
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func videoCRF(_ options: ConversionOptions) -> String {
        switch options.quality {
        case .compact: return "28"
        case .balanced: return "23"
        case .high: return "19"
        }
    }

    static func scaleFilter(_ options: ConversionOptions) -> [String] {
        guard options.videoMaxHeight > 0 else { return [] }
        return ["-vf", "scale=-2:'min(\(options.videoMaxHeight),ih)'"]
    }

    /// libx264 with yuv420p and wmv2 reject odd dimensions; sizes that are already even pass through unchanged.
    static let evenSize = "scale='2*max(1,trunc(iw/2))':'2*max(1,trunc(ih/2))'"

    static func evenScaleFilter(_ options: ConversionOptions) -> [String] {
        guard options.videoMaxHeight > 0 else { return ["-vf", evenSize] }
        // Spelled out rather than -2, which rounds the width of a hairline source down to 0.
        return ["-vf", "scale='max(2,2*trunc(oh*a/2+0.5))':'2*max(1,trunc(min(\(options.videoMaxHeight),ih)/2))'"]
    }

    static func sampleFormat(_ depth: AudioSampleDepth, bigEndian: Bool = false) -> String? {
        switch depth {
        case .matchSource: return nil
        case .bit16: return bigEndian ? "pcm_s16be" : "pcm_s16le"
        case .bit24: return bigEndian ? "pcm_s24be" : "pcm_s24le"
        case .bit32: return bigEndian ? "pcm_s32be" : "pcm_s32le"
        case .float32: return bigEndian ? "pcm_f32be" : "pcm_f32le"
        }
    }

    static func arguments(to target: ConversionFormat, from source: ConversionFormat, options: ConversionOptions) -> [String] {
        let bitrate = "\(options.audioBitrate)k"
        let isAudioOnlyTarget = target.group == .audio || target == .mp3
        var args: [String] = []
        if !options.preserveMetadata { args += ["-map_metadata", "-1"] }
        if isAudioOnlyTarget && source.group == .video { args += ["-vn"] }
        switch target {
        case .mp4, .mov, .mkv:
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", videoCRF(options), "-pix_fmt", "yuv420p"]
            args += evenScaleFilter(options)
            args += ["-c:a", "aac", "-b:a", bitrate]
            if target != .mkv { args += ["-movflags", "+faststart"] }
        case .webm:
            args += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p"] + scaleFilter(options) + ["-c:a", "libopus", "-b:a", bitrate]
        case .avi:
            args += ["-c:v", "mpeg4", "-q:v", options.quality == .high ? "3" : "5"] + scaleFilter(options) + ["-c:a", "libmp3lame", "-b:a", bitrate]
        case .wmv:
            args += ["-c:v", "wmv2", "-q:v", "4"] + evenScaleFilter(options) + ["-c:a", "wmav2", "-b:a", bitrate]
        case .gif:
            let width = options.gifMaxWidth > 0 ? options.gifMaxWidth : 640
            let graph = "fps=\(options.gifFrameRate),scale=min(\(width)\\,iw):-2:force_original_aspect_ratio=decrease,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
            args += ["-filter_complex", graph, "-loop", "0", "-an"]
        case .mp3: args += ["-c:a", "libmp3lame", "-b:a", bitrate]
        case .m4a: args += ["-c:a", "aac", "-b:a", bitrate]
        case .wav: args += ["-c:a", sampleFormat(options.audioSampleDepth) ?? "pcm_s16le"]
        case .aiff: args += ["-c:a", sampleFormat(options.audioSampleDepth, bigEndian: true) ?? "pcm_s16be"]
        case .flac: args += ["-c:a", "flac"]
        case .ogg, .opus: args += ["-c:a", "libopus", "-b:a", bitrate]
        case .wma: args += ["-c:a", "wmav2", "-b:a", bitrate]
        default: break
        }
        return args
    }

    static func convert(_ url: URL, from source: ConversionFormat, to target: ConversionFormat,
                        options: ConversionOptions, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let ffmpeg = ToolLocator.ffmpeg else { throw ConversionError.missingTool("ffmpeg") }
        let output = OutputNaming.destination(for: url, extension: target.fileExtension)
        let total = await duration(of: url)
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", url.path, "-progress", "pipe:1", "-nostats"]
        args += arguments(to: target, from: source, options: options)
        args.append(output.path)
        try await ProcessRunner.run(ffmpeg, args) { line in
            guard let total, total > 0, line.hasPrefix("out_time_us="),
                  let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(1, micros / 1_000_000 / total))
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.outputMissing }
        return output
    }
}
