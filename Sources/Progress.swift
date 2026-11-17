import Foundation

// MARK: - What the UI reads

/// A snapshot of one running transcription job. Read it from `JobRunner.progress[key]`.
///
/// - `fraction` is the progress of the whole job (0...1), or nil when it cannot be known
///   (a single cloud upload-and-wait has no honest percentage while the provider works).
/// - `stageFraction` is the progress of the current stage alone, for example the share of
///   bytes uploaded. nil when the stage is indeterminate (show a spinner).
struct JobProgress: Equatable, Sendable {
    enum Stage: String, Sendable {
        case preparing = "Preparing audio"
        case transcribing = "Transcribing"
        case uploading = "Uploading"
        case waiting = "Waiting for provider"
        case merging = "Merging parts"
    }

    var stage: Stage = .preparing
    var fraction: Double?
    var stageFraction: Double?
    /// Seconds since the job started. Refreshed about once a second.
    var elapsed: TimeInterval = 0
    /// Length of the recording in seconds, once known.
    var audioSeconds: Double?
    /// Estimated seconds left. nil until there is enough data for an honest estimate.
    var remaining: TimeInterval?
    /// Processing speed as a multiple of real time (2.0 means one minute of audio per 30 s).
    var speed: Double?
    /// Upload progress, set while `stage == .uploading`.
    var bytesSent: Int64?
    var bytesTotal: Int64?
    /// Chunked jobs only (cloud providers, recordings over about 60 minutes): part x of y.
    var part: Int?
    var parts: Int?
    /// A plain-language heads-up to show under the bar, for example a truncation risk or a fallback.
    var note: String?

    var stageName: String { stage.rawValue }
    var isChunked: Bool { (parts ?? 0) > 1 }
}

extension JobProgress {
    /// "1:05:09" or "4:07".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    var elapsedText: String { Self.clock(elapsed) }
    var remainingText: String? { remaining.map { Self.clock($0) } }
    var audioText: String? { audioSeconds.map { Self.clock($0) } }
    var speedText: String? { speed.map { String(format: "%.1f× real time", $0) } }
    var partText: String? { (parts ?? 0) > 1 ? part.map { "Part \($0) of \(parts ?? 0)" } : nil }
    var bytesText: String? {
        guard let sent = bytesSent, let total = bytesTotal else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: sent)) of \(f.string(fromByteCount: total))"
    }
}

// MARK: - Setting

/// Whether providers that can label speakers should. On by default. Bind a toggle with
/// `@AppStorage(SpeakerLabelsSetting.key)`.
enum SpeakerLabelsSetting {
    static let key = "speakerLabels"
    static var enabled: Bool {
        get { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Reporter

/// Collects what the engine knows and turns it into `JobProgress` snapshots. Thread-safe:
/// the engine calls it from any queue, `onChange` is called outside the lock. A one second
/// timer keeps `elapsed` and the countdown moving between real updates.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let onChange: @Sendable (JobProgress) -> Void
    private let start = Date()
    private var snapshot = JobProgress()
    private var finished = false
    private var timer: DispatchSourceTimer?

    private var stageStart = Date()
    // Local transcription: audio fraction reported by whisper-cli, with the stage-relative time of each rise.
    private var localFraction: Double = 0
    private var localSamples: [(t: TimeInterval, f: Double)] = []
    // Chunked cloud jobs.
    private var partLengths: [Double] = []
    private var partStarted = Date()
    private var completed: [(audio: Double, seconds: Double)] = []
    private var chunkFraction = 0.0

    init(onChange: @escaping @Sendable (JobProgress) -> Void) {
        self.onChange = onChange
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.update { _ in } }
        t.resume()
        timer = t
        publish(snapshotNow())
    }

    deinit { timer?.cancel() }

    /// Stops the timer and any further callbacks. Call when the job ends.
    func finish() {
        lock.lock()
        finished = true
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    var current: JobProgress { lock.lock(); defer { lock.unlock() }; return compute() }

    // MARK: Engine-facing updates

    func begin(_ stage: JobProgress.Stage) {
        update { me in
            me.snapshot.stage = stage
            me.stageStart = Date()
            me.snapshot.stageFraction = nil
            me.snapshot.bytesSent = nil
            me.snapshot.bytesTotal = nil
            if stage == .transcribing { me.localFraction = 0; me.localSamples = [] }
        }
    }

    func setAudio(seconds: Double) {
        guard seconds > 0 else { return }
        update { $0.snapshot.audioSeconds = seconds }
    }

    /// Local whisper: fraction of the audio transcribed so far (0...1). Never goes backwards.
    func transcribed(fraction: Double) {
        update { me in
            let f = min(1, max(me.localFraction, fraction))
            if f > me.localFraction || me.localSamples.isEmpty {
                me.localFraction = f
                if f > 0 { me.localSamples.append((Date().timeIntervalSince(me.stageStart), f)) }
            }
        }
    }

    /// Upload progress from the URLSession task delegate. Switches to "Waiting for provider"
    /// once every byte is out.
    func uploaded(sent: Int64, total: Int64) {
        update { me in
            guard total > 0 else { return }
            if sent >= total {
                if me.snapshot.stage == .uploading {
                    me.snapshot.stage = .waiting
                    me.stageStart = Date()
                    me.snapshot.stageFraction = nil
                    me.snapshot.bytesSent = nil
                    me.snapshot.bytesTotal = nil
                }
            } else {
                if me.snapshot.stage != .uploading { me.snapshot.stage = .uploading; me.stageStart = Date() }
                me.snapshot.bytesSent = sent
                me.snapshot.bytesTotal = total
                me.snapshot.stageFraction = Double(sent) / Double(total)
            }
        }
    }

    /// Declares the chunk plan (audio seconds per part), once, before the first part.
    func plan(parts lengths: [Double]) {
        update { me in
            me.partLengths = lengths
            me.snapshot.parts = lengths.count
            me.snapshot.part = 1
            me.completed = []
            me.chunkFraction = 0
        }
    }

    func beginPart(_ index: Int) {
        update { me in
            me.snapshot.part = index
            me.partStarted = Date()
            me.snapshot.stage = .preparing
            me.stageStart = Date()
            me.snapshot.stageFraction = nil
        }
    }

    /// Sets the heads-up text shown with the progress. Later notes replace earlier ones.
    func note(_ text: String?) {
        update { $0.snapshot.note = text }
    }

    func endPart(_ index: Int) {
        update { me in
            let audio = index - 1 < me.partLengths.count ? me.partLengths[index - 1] : 0
            me.completed.append((audio, Date().timeIntervalSince(me.partStarted)))
        }
    }

    // MARK: Internals

    private func update(_ change: (ProgressReporter) -> Void) {
        lock.lock()
        if finished { lock.unlock(); return }
        change(self)
        let snap = compute()
        lock.unlock()
        publish(snap)
    }

    private func snapshotNow() -> JobProgress { lock.lock(); defer { lock.unlock() }; return compute() }

    private func publish(_ p: JobProgress) { onChange(p) }

    /// Derives fraction, speed and remaining from the raw facts. Caller holds the lock.
    private func compute() -> JobProgress {
        var p = snapshot
        let now = Date()
        p.elapsed = now.timeIntervalSince(start)
        let stageElapsed = now.timeIntervalSince(stageStart)

        if let n = p.parts, n > 0, !partLengths.isEmpty {
            // Chunked cloud job: progress by audio completed.
            let total = partLengths.reduce(0, +)
            let doneAudio = completed.reduce(0) { $0 + $1.audio }
            let doneSecs = completed.reduce(0) { $0 + $1.seconds }
            let idx = max(1, min(p.part ?? 1, partLengths.count))
            let cur = partLengths[idx - 1]
            let finishedCur = completed.count >= idx   // between endPart and the next beginPart
            let partElapsed = finishedCur ? 0 : now.timeIntervalSince(partStarted)
            var within = 0.0
            var rate: Double?
            if doneAudio > 0, doneSecs > 0 { rate = doneSecs / doneAudio }
            if p.stage == .merging {
                p.fraction = 1
            } else {
                if let r = rate, cur > 0 {
                    within = min(0.95, partElapsed / (r * cur))
                } else {
                    switch p.stage {
                    case .uploading: within = 0.3 * (p.stageFraction ?? 0)
                    case .waiting: within = 0.3
                    default: within = 0
                    }
                }
                if total > 0 {
                    // Never step backwards when a better estimate of the current part arrives.
                    let f = min(0.99, (doneAudio + (finishedCur ? 0 : cur * within)) / total)
                    chunkFraction = max(chunkFraction, f)
                    p.fraction = chunkFraction
                }
            }
            if let r = rate {
                p.speed = 1 / r
                p.remaining = max(0, r * (total - doneAudio) - partElapsed)
            } else {
                p.speed = nil
                p.remaining = nil
            }
            return p
        }

        if p.stage == .transcribing, let audio = p.audioSeconds, audio > 0 {
            // Local whisper-cli.
            let f = localFraction
            p.fraction = f
            p.stageFraction = f
            if f > 0, let first = localSamples.first, let last = localSamples.last {
                var speed: Double
                if last.f - first.f >= 0.1, last.t > first.t {
                    speed = (last.f - first.f) * audio / (last.t - first.t)
                } else {
                    speed = f * audio / max(stageElapsed, 0.001)
                }
                if speed <= 0 { speed = 0.001 }
                p.speed = speed
                p.remaining = max(0, (1 - f) * audio / speed - (stageElapsed - last.t))
            }
            return p
        }
        if p.stage == .transcribing { p.fraction = localFraction > 0 ? localFraction : nil }
        return p
    }
}

// MARK: - whisper-cli progress lines

enum WhisperProgress {
    enum Event: Equatable {
        /// `whisper_print_progress_callback: progress =  40%`
        case percent(Int)
        /// A transcript line `[00:01:00.000 --> 00:01:04.180]  text`: the audio time reached.
        case reached(seconds: Double)
    }

    static func parse(_ rawLine: String) -> Event? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") { return segmentEnd(line).map { .reached(seconds: $0) } }
        guard let r = line.range(of: "progress =") else { return nil }
        let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        guard rest.hasSuffix("%"), let n = Int(rest.dropLast().trimmingCharacters(in: .whitespaces)),
              (0...100).contains(n) else { return nil }
        return .percent(n)
    }

    /// End time of a `[hh:mm:ss.mmm --> hh:mm:ss.mmm]` line, in seconds.
    static func segmentEnd(_ line: String) -> Double? {
        guard let arrow = line.range(of: "-->"), let close = line.firstIndex(of: "]"), arrow.upperBound < close else { return nil }
        let stamp = line[arrow.upperBound..<close].trimmingCharacters(in: .whitespaces)
        let parts = stamp.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

// MARK: - Speaker labels (ElevenLabs)

enum SpeakerFormat {
    /// Formats an ElevenLabs speech-to-text response. When the words carry at least two
    /// distinct `speaker_id`s, returns one line per turn ("Speaker 1: ..."), merging
    /// consecutive words of the same speaker. Otherwise returns the plain `text` exactly.
    static func format(_ json: [String: Any]) -> String? {
        let plain = json["text"] as? String
        guard let words = json["words"] as? [[String: Any]] else { return plain }
        let ids = words.compactMap { $0["speaker_id"] as? String }
        guard Set(ids).count >= 2 else { return plain }

        var order: [String: Int] = [:]
        var lines: [(speaker: String, text: String)] = []
        for w in words {
            if (w["type"] as? String) == "audio_event" { continue }
            guard let text = w["text"] as? String else { continue }
            if let id = w["speaker_id"] as? String {
                if order[id] == nil { order[id] = order.count + 1 }
                if lines.last?.speaker == id { lines[lines.count - 1].text += text } else { lines.append((id, text)) }
            } else if !lines.isEmpty {
                lines[lines.count - 1].text += text   // spacing between words of the same turn
            }
        }
        let out = lines.compactMap { l -> String? in
            let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : "Speaker \(order[l.speaker] ?? 0): \(t)"
        }
        return out.isEmpty ? plain : out.joined(separator: "\n")
    }
}

// MARK: - Upload progress

/// Per-task URLSession delegate that reports bytes sent. Pass it to `URLSession.upload(for:from:delegate:)`.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: @Sendable (Int64, Int64) -> Void
    init(_ handler: @escaping @Sendable (Int64, Int64) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        handler(totalBytesSent, totalBytesExpectedToSend)
    }
}

enum Net {
    /// Uploads `body` with progress reporting, then switches to "Waiting for provider".
    static func upload(_ req: URLRequest, body: Data, progress: ProgressReporter?) async throws -> (Data, URLResponse) {
        guard let progress else { return try await URLSession.shared.upload(for: req, from: body) }
        progress.begin(.uploading)
        progress.uploaded(sent: 0, total: Int64(max(body.count, 1)))
        let delegate = UploadProgressDelegate { sent, total in progress.uploaded(sent: sent, total: total) }
        let result = try await URLSession.shared.upload(for: req, from: body, delegate: delegate)
        return result
    }
}

// MARK: - Speaker segments

struct SpeakerSegment: Equatable, Sendable {
    var speaker: Int
    var text: String
}

enum SpeakerSegments {
    /// Splits a labelled transcript ("Speaker 1: ...") into segments. Returns nil unless at least two
    /// distinct speakers appear, so the UI shows speaker blocks only when speakers exist. A line
    /// without a label continues the previous segment.
    static func parse(_ transcript: String) -> [SpeakerSegment]? {
        var out: [SpeakerSegment] = []
        for raw in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Speaker "), let colon = line.firstIndex(of: ":"),
               let n = Int(line[line.index(line.startIndex, offsetBy: 8)..<colon]) {
                out.append(SpeakerSegment(speaker: n, text: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            } else if !out.isEmpty {
                out[out.count - 1].text += "\n" + line
            } else {
                return nil
            }
        }
        return Set(out.map(\.speaker)).count >= 2 ? out : nil
    }
}
