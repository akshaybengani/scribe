import Foundation
import AVFoundation

/// Splits very long recordings for cloud providers at the quietest point near each part boundary.
enum Chunker {
    /// Recordings longer than this are split.
    static let threshold: Double = 60 * 60
    /// Target length of each part.
    static let target: Double = 25 * 60
    /// How far either side of a target boundary to look for a quiet spot.
    static let window: Double = 90
    /// The last part is never shorter than this.
    static let minTail: Double = 60

    static let frameSeconds = 0.05
    /// Quietness is judged over this many frames (0.4 s) so a single click cannot fool it.
    static let smoothFrames = 8

    // MARK: Boundary choice (pure, tested with synthetic audio)

    /// Offset in seconds, within a stretch of frame RMS values, of the centre of the quietest
    /// run of `smoothFrames` frames. Ties go to the run closest to the middle of the stretch.
    static func quietestOffset(rms: [Float], frameSeconds: Double = Chunker.frameSeconds, smooth: Int = Chunker.smoothFrames) -> Double {
        guard !rms.isEmpty else { return 0 }
        let n = min(smooth, rms.count)
        var sum: Float = 0
        for i in 0..<n { sum += rms[i] * rms[i] }
        var best = sum, bestStart = 0
        let mid = Double(rms.count - n) / 2
        var i = n
        while i < rms.count {
            sum += rms[i] * rms[i] - rms[i - n] * rms[i - n]
            let start = i - n + 1
            // The epsilon stops float drift from beating an equally quiet run nearer the middle.
            if sum < best - 1e-9 || (abs(sum - best) <= 1e-9 && abs(Double(start) - mid) < abs(Double(bestStart) - mid)) {
                best = sum
                bestStart = start
            }
            i += 1
        }
        return (Double(bestStart) + Double(n) / 2) * frameSeconds
    }

    /// Cut points (seconds from the start) for a recording of `duration` seconds, or [] when
    /// no split is needed. `rms(start, length)` returns frame RMS values for that stretch.
    static func boundaries(duration: Double,
                           threshold: Double = Chunker.threshold, target: Double = Chunker.target,
                           window: Double = Chunker.window, minTail: Double = Chunker.minTail,
                           rms: (_ start: Double, _ length: Double) -> [Float]) -> [Double] {
        guard duration > threshold else { return [] }
        var cuts: [Double] = []
        var last = 0.0
        while duration - last > target + window {
            let lo = last + target - window
            let hi = min(last + target + window, duration - minTail)
            guard hi > lo else { break }
            let frames = rms(lo, hi - lo)
            let cut = lo + quietestOffset(rms: frames)
            let clamped = min(max(cut, lo), hi)
            cuts.append(clamped)
            last = clamped
        }
        return cuts
    }

    // MARK: WAV access

    struct WavLayout {
        var dataOffset: UInt64
        var dataBytes: UInt64
        var sampleRate: Int
        var channels: Int
        var bytesPerFrame: Int { channels * 2 }
        var duration: Double { Double(dataBytes) / Double(bytesPerFrame * sampleRate) }
    }

    /// Reads the header of a 16-bit PCM WAV (afconvert may insert padding chunks before the data).
    static func layout(of url: URL) throws -> WavLayout {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        try fh.seek(toOffset: 0)
        guard let riff = try fh.read(upToCount: 12), riff.count == 12,
              String(decoding: riff.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: riff[8..<12], as: UTF8.self) == "WAVE" else {
            throw TranscribeError.message("Not a WAV file.")
        }
        var rate = 16000, channels = 1, bits = 16
        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            try fh.seek(toOffset: offset)
            guard let h = try fh.read(upToCount: 8), h.count == 8 else { break }
            let id = String(decoding: h.prefix(4), as: UTF8.self)
            let size = UInt64(h.le32(at: 4))
            if id == "fmt " {
                guard let f = try fh.read(upToCount: Int(min(size, 40))), f.count >= 16 else { break }
                channels = Int(f.le16(at: 2))
                rate = Int(f.le32(at: 4))
                bits = Int(f.le16(at: 14))
            } else if id == "data" {
                guard bits == 16, channels >= 1, rate > 0 else { throw TranscribeError.message("Unsupported WAV format.") }
                let start = offset + 8
                var bytes = size
                if bytes == 0 || bytes == 0xFFFF_FFFF || start + bytes > fileSize { bytes = fileSize - start }
                return WavLayout(dataOffset: start, dataBytes: bytes - bytes % UInt64(channels * 2), sampleRate: rate, channels: channels)
            }
            offset += 8 + size + (size & 1)
        }
        throw TranscribeError.message("WAV file has no audio data.")
    }

    /// Frame RMS values (0...1) for a stretch of the file, from the first channel mixed down.
    static func rms(wav: URL, layout l: WavLayout, start: Double, length: Double) -> [Float] {
        guard let fh = try? FileHandle(forReadingFrom: wav) else { return [] }
        defer { try? fh.close() }
        let first = min(UInt64(max(0, start) * Double(l.sampleRate)) * UInt64(l.bytesPerFrame), l.dataBytes)
        let want = min(UInt64(max(0, length) * Double(l.sampleRate)) * UInt64(l.bytesPerFrame), l.dataBytes - first)
        guard want > 0, (try? fh.seek(toOffset: l.dataOffset + first)) != nil,
              let data = try? fh.read(upToCount: Int(want)) else { return [] }
        let framesPerWindow = max(1, Int(frameSeconds * Double(l.sampleRate)))
        let total = data.count / l.bytesPerFrame
        var out: [Float] = []
        out.reserveCapacity(total / framesPerWindow + 1)
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var i = 0
            while i < total {
                let end = min(i + framesPerWindow, total)
                var acc: Float = 0
                for f in i..<end {
                    let v = Float(Int16(littleEndian: s[f * l.channels])) / 32768
                    acc += v * v
                }
                out.append((acc / Float(end - i)).squareRoot())
                i = end
            }
        }
        return out
    }

    /// Writes seconds `from..<to` of a WAV into a new standard 44-byte-header WAV.
    static func slice(wav: URL, layout l: WavLayout, from: Double, to: Double, into out: URL) throws {
        let aFrom = UInt64(max(0, from) * Double(l.sampleRate)) * UInt64(l.bytesPerFrame)
        let aTo = min(UInt64(max(0, to) * Double(l.sampleRate)) * UInt64(l.bytesPerFrame), l.dataBytes)
        guard aTo > aFrom else { throw TranscribeError.message("Empty audio part.") }
        let bytes = aTo - aFrom
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        let r = try FileHandle(forReadingFrom: wav)
        defer { try? r.close() }
        try w.write(contentsOf: header(dataBytes: bytes, rate: l.sampleRate, channels: l.channels))
        try r.seek(toOffset: l.dataOffset + aFrom)
        var left = bytes
        while left > 0 {
            let n = Int(min(left, 4 << 20))
            guard let d = try r.read(upToCount: n), !d.isEmpty else { break }
            try w.write(contentsOf: d)
            left -= UInt64(d.count)
        }
    }

    static func header(dataBytes: UInt64, rate: Int, channels: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(UInt32(min(36 + dataBytes, UInt64(UInt32.max))))
        d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(rate)); u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(min(dataBytes, UInt64(UInt32.max))))
        return d
    }

    /// Plans the cut points of a 16 kHz WAV by scanning only the stretches near each boundary.
    static func plan(wav: URL, threshold: Double = Chunker.threshold) throws -> (layout: WavLayout, cuts: [Double]) {
        let l = try layout(of: wav)
        let cuts = boundaries(duration: l.duration, threshold: threshold) { start, length in rms(wav: wav, layout: l, start: start, length: length) }
        return (l, cuts)
    }
}

enum AudioInfo {
    /// Duration of any audio file macOS can open, in seconds. nil if it cannot be read.
    static func duration(of url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let rate = f.processingFormat.sampleRate
        return rate > 0 ? Double(f.length) / rate : nil
    }
}

private extension Data {
    func le16(at i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
    func le32(at i: Int) -> UInt32 {
        UInt32(self[startIndex + i]) | UInt32(self[startIndex + i + 1]) << 8
            | UInt32(self[startIndex + i + 2]) << 16 | UInt32(self[startIndex + i + 3]) << 24
    }
}
