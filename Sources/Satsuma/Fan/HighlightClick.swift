import Foundation

/// Satsuma's own highlight click, synthesized at launch (no audio asset). Shaped after the character
/// of the original `HighlightSound`: 60 ms, 48 kHz stereo, a ~5 ms bright tick around 8–10 kHz,
/// a faint 200 Hz knock and a quiet noise tail.
enum HighlightClick {
    static let sampleRate = 48_000
    static let duration = 0.06

    static func samples() -> [Float] {
        let count = Int(Double(sampleRate) * duration)
        let rate = Float(sampleRate)
        var seed: UInt32 = 0x5A75_C0DE
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }

        // Band-pass biquad (RBJ, constant 0 dB peak gain) for the bright part of the tick.
        let center: Float = 8_800, q: Float = 2.2
        let w0 = 2 * Float.pi * center / rate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0
        let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        let onset: Float = 0.001
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Float(i) / rate - onset
            guard t >= 0 else { continue }
            let attack = min(t / 0.0003, 1)
            let burst = noise() * attack * exp(-t / 0.0013)
            let bright = b0 * burst + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = burst; y2 = y1; y1 = bright
            let knock = sin(2 * .pi * 200 * t) * exp(-t / 0.003) * 0.05
            let tail = noise() * exp(-t / 0.018) * 0.012
            out[i] = bright * 2.4 + knock + tail
        }
        // Gentle fade on the last 5 ms so the buffer never ends on a step.
        let fade = Int(rate * 0.005)
        for k in 0..<fade { out[count - 1 - k] *= Float(k) / Float(fade) }

        let peak = out.map(abs).max() ?? 1
        let target: Float = 0.5
        return out.map { $0 / peak * target }
    }

    /// 16-bit stereo PCM WAV, ready for `NSSound(data:)`.
    static func wavData() -> Data {
        let pcm = samples().map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        let channels = 2, bytesPerSample = 2
        let dataSize = pcm.count * channels * bytesPerSample
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1))
        append(UInt16(channels)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * bytesPerSample)); append(UInt16(channels * bytesPerSample)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        for sample in pcm { append(sample); append(sample) }
        return data
    }
}
