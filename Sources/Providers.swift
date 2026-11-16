import Foundation

enum TranscribeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
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
        throw TranscribeError.message("\(who) returned \(h.statusCode): \(msg)")
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
    static func audio(style: OutputStyle, context: String, english: Bool = false) -> String {
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

struct LocalTranscriber {
    let whisper: String
    let model: String
    let language: String
    let hint: String
    var english = false

    func transcribe(audio: URL, context: String) async throws -> String {
        let tmp = try AudioPrep.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = try await AudioPrep.wav16k(audio, in: tmp)

        var prompt = english
            ? "This is a recording of a business call in English."
            : "Yeh ek meeting ki recording hai. Hum Hindi aur English mix karke baat kar rahe hain, jaise Hinglish."
        let extra = [hint, context].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !extra.isEmpty { prompt += " " + extra.joined(separator: ". ") }

        let outBase = tmp.appendingPathComponent("out").path
        // Settings from the model comparison: beam search, no carry-over between segments, no VAD.
        let args = ["-m", model, "-f", wav.path, "-l", english ? "en" : language, "-bs", "5", "-mc", "0", "-sns",
                    "--prompt", prompt, "-otxt", "-of", outBase]
        let r = try await Shell.run(whisper, args)
        guard r.status == 0 else { throw TranscribeError.message("whisper-cli failed: \(r.tail)") }
        guard let text = try? String(contentsOfFile: outBase + ".txt", encoding: .utf8) else {
            throw TranscribeError.message("whisper-cli produced no transcript.")
        }
        return tidy(text)
    }
}

// MARK: - Gemini

struct GeminiTranscriber {
    let key: String
    let model: String
    let style: OutputStyle
    var english = false

    private let host = "https://generativelanguage.googleapis.com"

    func transcribe(audio: URL, context: String) async throws -> String {
        let tmp = try AudioPrep.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let data = try Data(contentsOf: try await AudioPrep.compressed(audio, in: tmp, adts: true))

        let audioPart: [String: Any]
        if data.count <= 15_000_000 {
            audioPart = ["inline_data": ["mime_type": "audio/aac", "data": data.base64EncodedString()]]
        } else {
            let uri = try await upload(data)
            audioPart = ["file_data": ["mime_type": "audio/aac", "file_uri": uri]]
        }
        let body: [String: Any] = ["contents": [["parts": [["text": Prompts.audio(style: style, context: context, english: english)], audioPart]]]]

        let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var req = URLRequest(url: URL(string: "\(host)/v1beta/models/\(escaped):generateContent")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: req)
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

    /// Files API: resumable upload, then wait until Google has processed the file.
    private func upload(_ data: Data) async throws -> String {
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
        let (d2, r2) = try await URLSession.shared.upload(for: put, from: data)
        try httpCheck(r2, d2, who: "Gemini upload")
        guard let file = (try JSONSerialization.jsonObject(with: d2) as? [String: Any])?["file"] as? [String: Any],
              let uri = file["uri"] as? String, let name = file["name"] as? String else {
            throw TranscribeError.message("Gemini upload returned no file.")
        }

        var state = file["state"] as? String ?? "ACTIVE"
        var tries = 0
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

// MARK: - ElevenLabs

struct ElevenLabsTranscriber {
    let key: String
    let model: String
    var english = false

    func transcribe(audio: URL, context: String) async throws -> String {
        let tmp = try AudioPrep.tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try Data(contentsOf: try await AudioPrep.compressed(audio, in: tmp, adts: false))

        let boundary = "scribe-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", model)
        if english { field("language_code", "eng") }   // English-only call: skip language detection
        field("tag_audio_events", "false")
        field("diarize", "false")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (d, resp) = try await URLSession.shared.upload(for: req, from: body)
        try httpCheck(resp, d, who: "ElevenLabs")
        guard let text = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["text"] as? String else {
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

    func review(results: [TranscriptResult], context: String) async throws -> String {
        guard !results.isEmpty else { throw TranscribeError.message("Claude needs at least one existing transcript to review.") }
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

// MARK: - Dispatch and job tracking

enum Engine {
    static func run(_ kind: ProviderKind, audio: URL, existing: [TranscriptResult], cfg: Config,
                    language: CallLanguage = .mixed) async throws -> String {
        let english = language == .english
        switch kind {
        case .local:
            return try await LocalTranscriber(whisper: cfg.whisperPath, model: cfg.localPath(language),
                                              language: cfg.language, hint: cfg.hint, english: english)
                .transcribe(audio: audio, context: "")
        case .gemini:
            return try await GeminiTranscriber(key: cfg.geminiKey, model: cfg.geminiModel, style: cfg.style, english: english)
                .transcribe(audio: audio, context: cfg.hint)
        case .elevenlabs:
            return try await ElevenLabsTranscriber(key: cfg.elevenKey, model: cfg.elevenModel, english: english)
                .transcribe(audio: audio, context: cfg.hint)
        case .claude:
            return try await ClaudeReviewer(key: cfg.claudeKey, model: cfg.claudeModel, english: english)
                .review(results: existing, context: cfg.hint)
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

    private let store: RecordingStore
    private let settings: AppSettings

    init(store: RecordingStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func isRunning(_ rec: String, _ kind: ProviderKind) -> Bool { active[Key(rec: rec, kind: kind)] != nil }
    func error(_ rec: String, _ kind: ProviderKind) -> String? { errors[Key(rec: rec, kind: kind)] }
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
        let audio = store.audioURL(for: recording)
        let existing = recording.results
        let cfg = settings.config()
        Task {
            do {
                let text = try await Engine.run(kind, audio: audio, existing: existing, cfg: cfg, language: language)
                store.addResult(TranscriptResult(provider: kind, modelName: cfg.model(kind, language), text: text,
                                                 seconds: Date().timeIntervalSince(started), date: Date()), to: recording.id)
            } catch {
                errors[key] = error.localizedDescription
            }
            active[key] = nil
        }
    }
}
