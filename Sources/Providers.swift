import Foundation

enum TranscribeError: LocalizedError {
    case message(String)
    /// An HTTP error from a provider. Kept apart so long jobs can retry the transient ones.
    case http(status: Int, text: String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .http(_, let t): return t
        }
    }
    /// True for failures worth retrying: timeouts, dropped connections, 429 and 5xx.
    var isTransient: Bool {
        if case .http(let s, _) = self { return s == 429 || s >= 500 }
        return false
    }
}

func isTransient(_ error: Error) -> Bool {
    if let e = error as? TranscribeError { return e.isTransient }
    if let u = error as? URLError {
        switch u.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed: return true
        default: return false
        }
    }
    return false
}

// MARK: - Helpers

enum Shell {
    /// Runs a tool and returns its exit status and the tail of its output. Output goes to a
    /// file so a chatty tool such as whisper-cli can never block on a full pipe.
    static func run(_ exe: String, _ args: [String]) async throws -> (status: Int32, tail: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let log = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: log) }
                guard let h = try? FileHandle(forWritingTo: log) else {
                    cont.resume(throwing: TranscribeError.message("Could not create a temporary file."))
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.standardOutput = h
                p.standardError = h
                do { try p.run() } catch {
                    cont.resume(throwing: TranscribeError.message("Could not start \(exe): \(error.localizedDescription)"))
                    return
                }
                p.waitUntilExit()
                try? h.close()
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                cont.resume(returning: (p.terminationStatus, String(text.suffix(600))))
            }
        }
    }
}

extension Shell {
    /// Runs a tool and hands every output line (stdout and stderr merged, split on \n or \r) to
    /// `onLine` as it arrives. A background thread drains the pipe continuously, so the tool
    /// can never stall on a full pipe. Returns the exit status and the tail of non-progress output.
    static func runStreaming(_ exe: String, _ args: [String],
                             onLine: @escaping @Sendable (String) -> Void) async throws -> (status: Int32, tail: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let pipe = Pipe()
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(throwing: TranscribeError.message("Could not start \(exe): \(error.localizedDescription)"))
                    return
                }
                try? pipe.fileHandleForWriting.close()   // our copy; otherwise EOF never arrives
                let reader = pipe.fileHandleForReading
                var pending = Data()
                var recent: [String] = []
                func emit(_ bytes: Data) {
                    let line = String(decoding: bytes, as: UTF8.self)
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { return }
                    onLine(line)
                    if WhisperProgress.parse(line) == nil {
                        recent.append(line)
                        if recent.count > 30 { recent.removeFirst(recent.count - 30) }
                    }
                }
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }   // EOF
                    pending.append(chunk)
                    while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                        emit(pending[pending.startIndex..<i])
                        pending = pending[pending.index(after: i)...]
                    }
                }
                if !pending.isEmpty { emit(pending) }
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(recent.joined(separator: "\n").suffix(600))))
            }
        }
    }
}

enum AudioPrep {
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 16 kHz mono 16-bit WAV, the format whisper.cpp wants. Uses macOS's own afconvert.
    static func wav16k(_ src: URL, in dir: URL) async throws -> URL {
        let out = dir.appendingPathComponent("in.wav")
        let r = try await Shell.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src.path, out.path])
        guard r.status == 0 else { throw TranscribeError.message("Could not read this audio file. \(r.tail)") }
        return out
    }

    /// Small speech-quality AAC for uploads (about 14 MB per hour). adts for Gemini, m4a otherwise.
    static func compressed(_ src: URL, in dir: URL, adts: Bool) async throws -> URL {
        let out = dir.appendingPathComponent(adts ? "up.aac" : "up.m4a")
        let r = try await Shell.run("/usr/bin/afconvert",
                                    ["-f", adts ? "adts" : "m4af", "-d", "aac@16000", "-b", "32000", "-c", "1", src.path, out.path])
        guard r.status == 0 else { throw TranscribeError.message("Could not compress this audio file. \(r.tail)") }
        return out
    }
}

func httpCheck(_ resp: URLResponse, _ data: Data, who: String) throws {
    guard let h = resp as? HTTPURLResponse else { return }
    guard (200..<300).contains(h.statusCode) else {
        var msg = String(data: data, encoding: .utf8) ?? ""
        if msg.count > 400 { msg = String(msg.prefix(400)) }
        throw TranscribeError.http(status: h.statusCode, text: "\(who) returned \(h.statusCode): \(msg)")
    }
}

func tidy(_ text: String) -> String {
    var out: [String] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line == out.last { continue }  // drops the repeat loops Whisper sometimes makes
        out.append(line)
    }
    return out.joined(separator: "\n")
}

enum Prompts {
    static func audio(style: OutputStyle, context: String, english: Bool = false, previous: String = "") -> String {
        let script = style == .roman
            ? "Write Hindi words in Roman script (Hinglish) and English words in normal English spelling."
            : "Write Hindi words in Devanagari and English words in Latin script."
        var p = english
            ? """
              Transcribe this audio verbatim in English. The speakers speak English only. \
              Keep every spoken part in order. Do not summarise or add commentary. \
              Mark unclear audio as [unclear]. Speaker labels are not needed. Output only the transcript.
              """
            : """
              Transcribe this audio verbatim. The speakers mix Hindi and English. \(script) \
              Keep every spoken part in order. Do not translate, summarise or add commentary. \
              Mark unclear audio as [unclear]. Speaker labels are not needed. Output only the transcript.
              """
        let c = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { p += "\n\nNames and terms that may appear: \(c)" }
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prev.isEmpty {
            p += "\n\nThis audio is one part of a longer recording and continues from the previous part. "
                + "The previous part ended with these lines. Use them only for context, spelling and continuity. "
                + "Do not repeat them:\n" + prev
        }
        return p
    }

    static func review(sources: String, context: String, english: Bool = false) -> String {
        let language = english
            ? "which is in English. "
            : "which mixes Hindi and English. "
        let writing = english
            ? "Write it in normal English spelling, one sentence or turn per line."
            : "Write Hindi in Roman script (Hinglish) and English words in normal English spelling, one sentence or turn per line."
        var p = """
        Below are several imperfect machine transcripts of the same conversation, \(language)\
        You cannot hear the audio. Produce ONE best transcript: where they disagree, choose the wording that is most \
        plausible in context and best supported by the sources. Keep every spoken part in order; do not summarise, \
        shorten, translate or invent content. \(writing) Output only the transcript.
        """
        let c = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { p += "\n\nNames and terms that may appear: \(c)" }
        return p + "\n\n" + sources
    }
}


// MARK: - Local (whisper.cpp)

/// Every output line of one whisper-cli run, filled from the reader thread.
final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

/// Local whisper jobs run one at a time. Each loads a model of up to 1.6 GB onto the GPU, and two at
/// once can make one fail partway through a long recording. Waiting jobs start in the order they came.
actor LocalQueue {
    static let shared = LocalQueue()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

struct LocalTranscriber {
    let whisper: String
    let model: String
    let language: String
    let hint: String
    var english = false

    func transcribe(audio: URL, context: String, progress: ProgressReporter? = nil) async throws -> String {
        progress?.begin(.preparing)
        let tmp = try AudioPrep.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = try await AudioPrep.wav16k(audio, in: tmp)
        let seconds = (try? Chunker.layout(of: wav))?.duration ?? 0
        progress?.setAudio(seconds: seconds)

        var prompt = english
            ? "This is a recording of a business call in English."
            : "Yeh ek meeting ki recording hai. Hum Hindi aur English mix karke baat kar rahe hain, jaise Hinglish."
        let extra = [hint, context].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !extra.isEmpty { prompt += " " + extra.joined(separator: ". ") }

        let outBase = tmp.appendingPathComponent("out").path
        // Settings from the model comparison: beam search, no carry-over between segments, no VAD.
        // -pp prints "progress = N%" every 10%; the timestamps on printed segments give finer steps.
        let args = ["-m", model, "-f", wav.path, "-l", english ? "en" : language, "-bs", "5", "-mc", "0", "-sns",
                    "--prompt", prompt, "-otxt", "-of", outBase, "-pp"]
        progress?.begin(.transcribing)
        let total = seconds
        let log = LineLog()
        // Written next to the audio when whisper-cli fails, so the cause is never lost with the screen.
        let logFile = audio.deletingLastPathComponent().appendingPathComponent("whisper-error.log")
        func saveLog(_ status: Int32) {
            let head = "whisper-cli exited with status \(status) on \(Date())\nAudio: \(Int(seconds)) s, model: \(model)\n\n"
            try? (head + log.text).write(to: logFile, atomically: true, encoding: .utf8)
        }
        let r = try await Shell.runStreaming(whisper, args) { line in
            log.append(line)
            guard let event = WhisperProgress.parse(line) else { return }
            switch event {
            case .percent(let n): progress?.transcribed(fraction: Double(n) / 100)
            case .reached(let t): if total > 0 { progress?.transcribed(fraction: min(0.99, t / total)) }
            }
        }
        guard r.status == 0 else {
            saveLog(r.status)
            throw TranscribeError.message("whisper-cli failed (status \(r.status)). The full log is saved as whisper-error.log in this recording's folder. \(r.tail)")
        }
        progress?.transcribed(fraction: 1)
        // Decode leniently: whisper sometimes writes a broken UTF-8 byte (half a character) inside a
        // hallucinated line, and a strict read would throw away an otherwise finished transcript.
        guard let data = FileManager.default.contents(atPath: outBase + ".txt") else {
            saveLog(r.status)
            throw TranscribeError.message("whisper-cli produced no transcript. The full log is saved as whisper-error.log in this recording's folder.")
        }
        try? FileManager.default.removeItem(at: logFile)
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "")
        // Drop whisper's hallucinated lines (Korean, Japanese, Arabic... in a Hindi and English call).
        return tidy(TranscriptCleanup.clean(text).text)
    }
}

// MARK: - Cloud providers: shared chunking

/// One request to a cloud provider for one (possibly whole) recording.
protocol CloudPartTranscriber: Sendable {
    /// True when the provider wants ADTS AAC (Gemini), false for m4a.
    var adts: Bool { get }
    /// Recordings longer than this (seconds) are split into parts. Defaults to 60 minutes.
    var chunkThreshold: Double { get }
    /// Shown in the job's progress text when the recording is split. nil for no note.
    var chunkNote: String? { get }
    func transcribe(part file: URL, context: String, previous: String, progress: ProgressReporter?) async throws -> String
}

extension CloudPartTranscriber {
    var chunkThreshold: Double { Chunker.threshold }
    var chunkNote: String? { nil }
}

enum CloudRunner {
    /// Short recordings go up in one piece. Recordings over about 60 minutes are split at the
    /// quietest point near each 25 minute boundary and transcribed in order, each part given the
    /// last few lines of the one before it as context, then stitched together.
    static func run(_ t: CloudPartTranscriber, audio: URL, context: String, progress: ProgressReporter?) async throws -> String {
        progress?.begin(.preparing)
        let tmp = try AudioPrep.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let duration = AudioInfo.duration(of: audio) ?? 0
        progress?.setAudio(seconds: duration)
        guard duration > t.chunkThreshold else {
            let file = try await AudioPrep.compressed(audio, in: tmp, adts: t.adts)
            return try await t.transcribe(part: file, context: context, previous: "", progress: progress)
        }

        let wav = try await AudioPrep.wav16k(audio, in: tmp)
        let (layout, cuts) = try Chunker.plan(wav: wav, threshold: t.chunkThreshold)
        let edges = [0.0] + cuts + [layout.duration]
        let lengths = (0..<(edges.count - 1)).map { edges[$0 + 1] - edges[$0] }
        progress?.setAudio(seconds: layout.duration)
        progress?.plan(parts: lengths)
        if lengths.count > 1, let note = t.chunkNote { progress?.note(note) }

        var texts: [String] = []
        for i in 0..<lengths.count {
            progress?.beginPart(i + 1)
            let dir = tmp.appendingPathComponent("part\(i + 1)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let slice = dir.appendingPathComponent("slice.wav")
            try Chunker.slice(wav: wav, layout: layout, from: edges[i], to: edges[i + 1], into: slice)
            let file = try await AudioPrep.compressed(slice, in: dir, adts: t.adts)
            try? FileManager.default.removeItem(at: slice)
            let previous = lastLines(texts.last ?? "")
            do {
                texts.append(try await withRetry { try await t.transcribe(part: file, context: context, previous: previous, progress: progress) })
            } catch {
                throw TranscribeError.message("Part \(i + 1) of \(lengths.count) failed: \(error.localizedDescription)")
            }
            progress?.endPart(i + 1)
            try? FileManager.default.removeItem(at: dir)
        }
        progress?.begin(.merging)
        return tidy(texts.joined(separator: "\n"))
    }

    /// The last few lines of a transcript, handed to the next part as context.
    static func lastLines(_ text: String, count: Int = 4, maxChars: Int = 600) -> String {
        let lines = text.split(separator: "\n").suffix(count).joined(separator: "\n")
        return String(lines.suffix(maxChars))
    }

    /// Up to three attempts for transient failures (timeouts, dropped connections, 429, 5xx).
    static func withRetry(_ body: () async throws -> String) async throws -> String {
        var attempt = 0
        while true {
            do { return try await body() } catch {
                attempt += 1
                guard attempt < 3, isTransient(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 6_000_000_000)
            }
        }
    }
}

// MARK: - Gemini

/// Shared between the parts of one job so a rejected diarization request is only tried once.
final class DiarizationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var dropped = false
    var isDropped: Bool { lock.lock(); defer { lock.unlock() }; return dropped }
    func drop() { lock.lock(); dropped = true; lock.unlock() }
}

struct GeminiTranscriber: CloudPartTranscriber {
    let key: String
    let model: String
    let style: OutputStyle
    var english = false
    /// gemini-3.5-transcribe only: label speakers ("Speaker 1: ..."). On by default.
    var speakerLabels = true
    /// gemini-3.5-transcribe only: "smart" mode (cleaned-up text, no diarization) instead of verbatim.
    var smart = false

    private let host = "https://generativelanguage.googleapis.com"
    private let diarization = DiarizationFlag()
    var adts: Bool { true }

    /// gemini-3.5-transcribe (not the -live variant) is a transcription model served by the
    /// Interactions API. Every other Gemini id is a generateContent text model.
    var usesInteractions: Bool { model.hasPrefix("gemini-3.5-transcribe") }
    private var diarizing: Bool { usesInteractions && speakerLabels && !smart && !diarization.isDropped }

    /// With diarization on Google silently truncates a request at 30 minutes (status still says
    /// completed), so split earlier than the usual 60 minutes and keep every part under the cap.
    var chunkThreshold: Double { diarizing ? 29 * 60 : Chunker.threshold }
    var chunkNote: String? {
        diarizing ? "Speaker labels limit each request to 30 minutes, so this recording is sent in parts of about 25 minutes. Speaker numbers may not match between parts." : nil
    }

    func transcribe(audio: URL, context: String, progress: ProgressReporter? = nil) async throws -> String {
        if model.hasSuffix("-live") {
            throw TranscribeError.message("\(model) is for live streaming only and cannot transcribe a recording. Choose gemini-3.5-transcribe.")
        }
        return try await CloudRunner.run(self, audio: audio, context: context, progress: progress)
    }

    func transcribe(part file: URL, context: String, previous: String, progress: ProgressReporter?) async throws -> String {
        let data = try Data(contentsOf: file)
        if usesInteractions { return try await interactions(data, context: context, progress: progress) }

        let isInline = data.count <= 15_000_000
        let audioPart: [String: Any]
        if isInline {
            audioPart = ["inline_data": ["mime_type": "audio/aac", "data": data.base64EncodedString()]]
        } else {
            let uri = try await upload(data, progress: progress)
            audioPart = ["file_data": ["mime_type": "audio/aac", "file_uri": uri]]
        }
        let body: [String: Any] = ["contents": [["parts": [["text": Prompts.audio(style: style, context: context, english: english, previous: previous)], audioPart]]]]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var req = URLRequest(url: URL(string: "\(host)/v1beta/models/\(escaped):generateContent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let d: Data, resp: URLResponse
        if isInline {
            (d, resp) = try await Net.upload(req, body: bodyData, progress: progress)   // audio is inline: this is the upload
        } else {
            progress?.begin(.waiting)
            req.httpBody = bodyData
            (d, resp) = try await URLSession.shared.data(for: req)
        }
        try httpCheck(resp, d, who: "Gemini")

        guard let json = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cand = (json["candidates"] as? [[String: Any]])?.first,
              let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] else {
            throw TranscribeError.message("Gemini returned no transcript.")
        }
        var text = parts.compactMap { $0["text"] as? String }.joined()
        if (cand["finishReason"] as? String) == "MAX_TOKENS" { text += "\n[The model hit its output limit, so the end of this transcript is missing.]" }
        return tidy(text)
    }

    // MARK: Interactions API (gemini-3.5-transcribe)

    /// Always uploads through the Files API and passes the file uri: the docs show no inline
    /// base64 audio for REST. The model has no prompt, so the previous part's text is not sent.
    private func interactions(_ data: Data, context: String, progress: ProgressReporter?) async throws -> String {
        let uri = try await upload(data, progress: progress)
        let options = GeminiInteractions.Options(diarize: speakerLabels && !smart, smart: smart,
                                                 languages: english ? ["en-IN"] : [],
                                                 vocabulary: GeminiInteractions.vocabulary(from: context))
        let apiHost = host
        let apiKey = key
        let send: @Sendable (Data) async throws -> (Data, Int) = { body in
            progress?.begin(.waiting)
            var req = URLRequest(url: URL(string: "\(apiHost)/v1beta/interactions")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 1800
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let (d, resp) = try await URLSession.shared.data(for: req)
            return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let text = try await GeminiInteractions.transcribe(model: model, fileURI: uri, mime: "audio/aac", options: options,
                                                           flag: diarization, progress: progress, send: send)
        return tidy(text)
    }

    /// Files API: resumable upload, then wait until Google has processed the file.
    private func upload(_ data: Data, progress: ProgressReporter?) async throws -> String {
        var start = URLRequest(url: URL(string: "\(host)/upload/v1beta/files")!)
        start.httpMethod = "POST"
        start.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("audio/aac", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": "scribe-audio"]])
        let (d1, r1) = try await URLSession.shared.data(for: start)
        try httpCheck(r1, d1, who: "Gemini upload")
        guard let h = r1 as? HTTPURLResponse, let up = h.value(forHTTPHeaderField: "X-Goog-Upload-URL"), let upURL = URL(string: up) else {
            throw TranscribeError.message("Gemini did not return an upload address.")
        }

        var put = URLRequest(url: upURL)
        put.httpMethod = "POST"
        put.timeoutInterval = 1800
        put.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        put.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let (d2, r2) = try await Net.upload(put, body: data, progress: progress)
        try httpCheck(r2, d2, who: "Gemini upload")
        guard let file = (try JSONSerialization.jsonObject(with: d2) as? [String: Any])?["file"] as? [String: Any],
              let uri = file["uri"] as? String, let name = file["name"] as? String else {
            throw TranscribeError.message("Gemini upload returned no file.")
        }

        var state = file["state"] as? String ?? "ACTIVE"
        var tries = 0
        if state == "PROCESSING" { progress?.begin(.waiting) }
        while state == "PROCESSING" && tries < 150 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            var poll = URLRequest(url: URL(string: "\(host)/v1beta/\(name)")!)
            poll.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let (d3, r3) = try await URLSession.shared.data(for: poll)
            try httpCheck(r3, d3, who: "Gemini")
            state = ((try JSONSerialization.jsonObject(with: d3) as? [String: Any])?["state"] as? String) ?? "ACTIVE"
            tries += 1
        }
        guard state == "ACTIVE" else { throw TranscribeError.message("Gemini could not process the audio file (state: \(state)).") }
        return uri
    }
}

/// Request building, response parsing and the diarization fallback for gemini-3.5-transcribe.
/// Pure and transport-free so the harness can test it with canned JSON.
enum GeminiInteractions {
    struct Options: Equatable {
        var diarize = true
        var smart = false
        /// BCP-47 codes such as "hi-IN". Empty means auto-detect, which is best for Hinglish.
        var languages: [String] = []
        var vocabulary: [String] = []
    }

    enum Input { case file(uri: String), audio(uri: String, mime: String) }

    /// POST /v1beta/interactions body. Option rules from the docs: custom_vocabulary cannot be
    /// combined with diarization or word timestamps, and smart mode cannot be combined with
    /// either. Word timestamps are never requested.
    static func body(model: String, input: Input, options o: Options) -> [String: Any] {
        let block: [String: Any]
        switch input {
        case .file(let uri): block = ["type": "file", "file_uri": uri]
        // Fallback only: the docs' JS example uses an "audio" block with uri and mime_type, while the
        // REST example uses "file". We try this once if the file form is rejected.
        case .audio(let uri, let mime): block = ["type": "audio", "uri": uri, "mime_type": mime]
        }
        var cfg: [String: Any] = [:]
        if !o.languages.isEmpty { cfg["language_codes"] = o.languages }
        if o.smart {
            cfg["mode"] = "smart"
        } else if o.diarize {
            cfg["mode"] = ["type": "verbatim", "diarization_mode": "speaker"] as [String: Any]
        }
        if !o.vocabulary.isEmpty, !o.diarize || o.smart { cfg["custom_vocabulary"] = Array(o.vocabulary.prefix(100)) }
        var out: [String: Any] = ["model": model.hasPrefix("models/") ? model : "models/\(model)", "input": [block]]
        if !cfg.isEmpty { out["generation_config"] = ["transcription_config": cfg] }
        return out
    }

    /// Terms from the "names and terms" hint, split on commas and newlines.
    static func vocabulary(from hint: String) -> [String] {
        hint.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    struct Word: Equatable { var text: String; var speaker: String? }
    struct Parsed: Equatable {
        var text: String
        var words: [Word]
        var status: String?
        var error: String?
    }

    /// Defensive: the docs do not show the raw REST response. Walks the tree in document order
    /// (array order, dictionary keys sorted), collecting plain text from text blocks and word_info
    /// annotations. Our own "input" is skipped.
    static func parse(_ data: Data) throws -> Parsed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscribeError.message("Gemini returned no transcript.")
        }
        var texts: [String] = []
        var words: [Word] = []
        func walk(_ node: Any) {
            if let arr = node as? [Any] { arr.forEach(walk); return }
            guard let d = node as? [String: Any] else { return }
            let type = d["type"] as? String
            if type == "word_info", let t = d["text"] as? String {
                words.append(Word(text: t, speaker: d["speaker"] as? String))
                return
            }
            if type == "text", let t = d["text"] as? String { texts.append(t) }
            for k in d.keys.sorted() where k != "text" && k != "input" { walk(d[k]!) }
        }
        walk(root["steps"] ?? root["outputs"] ?? [])
        var text = texts.joined()
        if text.isEmpty, let t = root["output_text"] as? String { text = t }
        let err = (root["error"] as? [String: Any])?["message"] as? String ?? root["error"] as? String
        return Parsed(text: text, words: words, status: root["status"] as? String, error: err)
    }

    /// "spk_3" -> 3. nil when the id has no number.
    static func speakerNumber(_ id: String) -> Int? {
        Int(String(id.reversed().prefix(while: { $0.isNumber }).reversed()))
    }

    /// Speaker-labelled lines when the words carry two or more distinct speakers, else plain text.
    static func format(_ p: Parsed) -> String {
        let ids = p.words.compactMap(\.speaker)
        let distinct = Set(ids)
        guard distinct.count >= 2 else {
            return p.text.isEmpty ? p.words.map(\.text).joined(separator: " ") : p.text
        }
        // spk_N becomes "Speaker N" (shifted up by one if the ids start at 0). Without numbers, by first appearance.
        let nums = distinct.compactMap(speakerNumber)
        let useNumbers = nums.count == distinct.count && Set(nums).count == nums.count
        let shift = useNumbers && nums.min() == 0 ? 1 : 0
        var order: [String: Int] = [:]
        for id in ids where order[id] == nil { order[id] = order.count + 1 }
        func label(_ id: String) -> Int { useNumbers ? (speakerNumber(id) ?? 0) + shift : (order[id] ?? 0) }

        var lines: [(id: String?, words: [String])] = []
        for w in p.words {
            if let id = w.speaker {
                if lines.last?.id == id { lines[lines.count - 1].words.append(w.text) } else { lines.append((id, [w.text])) }
            } else if !lines.isEmpty {
                lines[lines.count - 1].words.append(w.text)
            } else {
                lines.append((nil, [w.text]))
            }
        }
        return lines.compactMap { l -> String? in
            let t = l.words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            guard let id = l.id else { return t }
            return "Speaker \(label(id)): \(t)"
        }.joined(separator: "\n")
    }

    /// One part: diarized request first; a 400 retries once without diarization (and tells the other
    /// parts to skip it); a 400 on that too tries the "audio" input block once.
    static func transcribe(model: String, fileURI: String, mime: String, options: Options, flag: DiarizationFlag,
                           progress: ProgressReporter?,
                           send: @Sendable (Data) async throws -> (Data, Int)) async throws -> String {
        var o = options
        if flag.isDropped { o.diarize = false }
        func attempt(_ input: Input, _ o: Options) async throws -> (Data, Int) {
            try await send(JSONSerialization.data(withJSONObject: body(model: model, input: input, options: o)))
        }
        var (data, status) = try await attempt(.file(uri: fileURI), o)
        if status == 400, o.diarize {
            flag.drop()
            o.diarize = false
            progress?.note("Speaker labels were rejected for this audio, so this transcript has none.")
            (data, status) = try await attempt(.file(uri: fileURI), o)
        }
        if status == 400 {
            let first = errorText(data, status)
            let retry = try await attempt(.audio(uri: fileURI, mime: mime), o)
            if (200..<300).contains(retry.1) { (data, status) = retry } else { throw TranscribeError.http(status: status, text: first) }
        }
        guard (200..<300).contains(status) else { throw TranscribeError.http(status: status, text: errorText(data, status)) }

        let parsed = try parse(data)
        if let e = parsed.error { throw TranscribeError.message("Gemini failed: \(e)") }
        if let s = parsed.status, s.lowercased() != "completed" {
            throw TranscribeError.message("Gemini transcription ended with status \(s).")
        }
        let out = format(parsed)
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscribeError.message("Gemini returned no transcript.")
        }
        return out
    }

    private static func errorText(_ data: Data, _ status: Int) -> String {
        var msg = String(data: data, encoding: .utf8) ?? ""
        if msg.count > 400 { msg = String(msg.prefix(400)) }
        return "Gemini returned \(status): \(msg)"
    }
}

// MARK: - ElevenLabs

struct ElevenLabsTranscriber: CloudPartTranscriber {
    let key: String
    let model: String
    var english = false
    /// Ask ElevenLabs to tell speakers apart and label the transcript "Speaker 1: ...".
    var speakerLabels = true

    var adts: Bool { false }

    func transcribe(audio: URL, context: String, progress: ProgressReporter? = nil) async throws -> String {
        try await CloudRunner.run(self, audio: audio, context: context, progress: progress)
    }

    func transcribe(part file: URL, context: String, previous: String, progress: ProgressReporter?) async throws -> String {
        let audioData = try Data(contentsOf: file)

        let boundary = "scribe-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", model)
        if english { field("language_code", "eng") }   // English-only call: skip language detection
        field("tag_audio_events", "false")
        field("diarize", speakerLabels ? "true" : "false")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await Net.upload(req, body: body, progress: progress)
        try httpCheck(resp, d, who: "ElevenLabs")
        guard let json = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let text = speakerLabels ? SpeakerFormat.format(json) : json["text"] as? String else {
            throw TranscribeError.message("ElevenLabs returned no transcript.")
        }
        return tidy(text)
    }
}

// MARK: - Claude (text only)

struct ClaudeReviewer {
    let key: String
    let model: String
    var english = false

    func review(results: [TranscriptResult], context: String, progress: ProgressReporter? = nil) async throws -> String {
        guard !results.isEmpty else { throw TranscribeError.message("Claude needs at least one existing transcript to review.") }
        progress?.begin(.waiting)
        var sources = ""
        for (i, r) in results.enumerated() {
            sources += "=== Transcript \(i + 1): \(r.provider.short), \(r.modelName) ===\n\(r.text)\n\n"
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "messages": [["role": "user", "content": Prompts.review(sources: sources, context: context, english: english)]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: req)
        try httpCheck(resp, d, who: "Claude")
        guard let blocks = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["content"] as? [[String: Any]] else {
            throw TranscribeError.message("Claude returned no text.")
        }
        return tidy(blocks.compactMap { $0["text"] as? String }.joined())
    }
}

/// The same review as `ClaudeReviewer`, run through Claude Code on the user's Claude subscription.
struct ClaudeCodeReviewer {
    let model: String
    var english = false

    func review(results: [TranscriptResult], context: String, progress: ProgressReporter? = nil) async throws -> String {
        // Never review its own earlier output: start from the transcripts that came from audio or the API review.
        let results = results.filter { $0.provider != .claudeCode }
        guard !results.isEmpty else { throw TranscribeError.message("Claude Code needs at least one existing transcript to review.") }
        progress?.begin(.waiting)
        var sources = ""
        for (i, r) in results.enumerated() {
            sources += "=== Transcript \(i + 1): \(r.provider.short), \(r.modelName) ===\n\(r.text)\n\n"
        }
        let buffer = TextBuffer()
        try await ClaudeCode.run(model: model,
                                 system: "You review call transcripts and return one corrected transcript. Follow the instructions exactly and output only the transcript.",
                                 user: Prompts.review(sources: sources, context: context, english: english)) { t in
            _ = buffer.append(t)
        }
        let text = buffer.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscribeError.message("Claude Code returned no text.") }
        return tidy(text)
    }
}

// MARK: - Dispatch and job tracking

enum Engine {
    static func run(_ kind: ProviderKind, audio: URL, existing: [TranscriptResult], cfg: Config,
                    language: CallLanguage = .mixed, speakerLabels: Bool = SpeakerLabelsSetting.enabled,
                    progress: ProgressReporter? = nil) async throws -> String {
        let english = language == .english
        switch kind {
        case .local:
            progress?.begin(.queued)
            await LocalQueue.shared.acquire()
            do {
                let text = try await LocalTranscriber(whisper: cfg.whisperPath, model: cfg.localPath(language),
                                                      language: cfg.language, hint: cfg.hint, english: english)
                    .transcribe(audio: audio, context: "", progress: progress)
                await LocalQueue.shared.release()
                return text
            } catch {
                await LocalQueue.shared.release()
                throw error
            }
        case .gemini:
            return try await GeminiTranscriber(key: cfg.geminiKey, model: cfg.geminiModel, style: cfg.style, english: english,
                                               speakerLabels: speakerLabels)
                .transcribe(audio: audio, context: cfg.hint, progress: progress)
        case .elevenlabs:
            return try await ElevenLabsTranscriber(key: cfg.elevenKey, model: cfg.elevenModel, english: english,
                                                   speakerLabels: speakerLabels)
                .transcribe(audio: audio, context: cfg.hint, progress: progress)
        case .claude:
            return try await ClaudeReviewer(key: cfg.claudeKey, model: cfg.claudeModel, english: english)
                .review(results: existing, context: cfg.hint, progress: progress)
        case .claudeCode:
            return try await ClaudeCodeReviewer(model: cfg.claudeCodeModel, english: english)
                .review(results: existing, context: cfg.hint, progress: progress)
        }
    }
}

@MainActor
final class JobRunner: ObservableObject {
    struct Key: Hashable {
        let rec: String
        let kind: ProviderKind
    }

    @Published private(set) var active: [Key: Date] = [:]
    @Published private(set) var errors: [Key: String] = [:]
    /// Live numbers for every running job. An entry exists only while its job runs.
    @Published private(set) var progress: [Key: JobProgress] = [:]

    private let store: RecordingStore
    private let settings: AppSettings

    init(store: RecordingStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func isRunning(_ rec: String, _ kind: ProviderKind) -> Bool { active[Key(rec: rec, kind: kind)] != nil }
    func error(_ rec: String, _ kind: ProviderKind) -> String? { errors[Key(rec: rec, kind: kind)] }
    func progress(_ rec: String, _ kind: ProviderKind) -> JobProgress? { progress[Key(rec: rec, kind: kind)] }
    func dismissError(_ rec: String, _ kind: ProviderKind) { errors[Key(rec: rec, kind: kind)] = nil }
    var runningCloudKinds: Set<ProviderKind> { Set(active.keys.map(\.kind).filter(\.isCloud)) }

    func start(_ recording: Recording, kind: ProviderKind) {
        let key = Key(rec: recording.id, kind: kind)
        guard active[key] == nil else { return }
        let language = recording.callLanguage
        if let issue = settings.issue(for: kind, language: language) {
            errors[key] = issue
            return
        }
        errors[key] = nil
        let started = Date()
        active[key] = started
        progress[key] = JobProgress()
        let audio = store.audioURL(for: recording)
        let existing = recording.results
        let cfg = settings.config()
        let labels = SpeakerLabelsSetting.enabled
        let reporter = ProgressReporter { snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Ignore a late snapshot from a job that has already ended.
                    if self.active[key] == started { self.progress[key] = snapshot }
                }
            }
        }
        Task {
            // Keep the Mac from idle-sleeping mid-job: a long local transcription runs for many minutes.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                                 reason: "Transcribing a recording")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let text = try await Engine.run(kind, audio: audio, existing: existing, cfg: cfg, language: language,
                                                speakerLabels: labels, progress: reporter)
                store.addResult(TranscriptResult(provider: kind, modelName: cfg.model(kind, language), text: text,
                                                 seconds: Date().timeIntervalSince(started), date: Date()), to: recording.id)
            } catch {
                errors[key] = error.localizedDescription
            }
            reporter.finish()
            active[key] = nil
            progress[key] = nil
        }
    }
}
