import Foundation
import Combine

// Meeting notes from a transcript, written by a local Ollama model or by Claude through Claude Code.
//
//   NotesPrompt     the instructions and the transcript, the same for both engines
//   OllamaClient    lists models, reads a model's context size, streams /api/chat (localhost only)
//   ClaudeCodeNotes runs `claude -p` on the signed-in Claude Code subscription (text only; never audio)
//   NotesRunner     one job per recording, live text, cancel, saves the result on the recording

// MARK: - Prompt

enum NotesPrompt {
    static let system = "You write accurate, well-organised meeting notes from call transcripts. "
        + "Write only the notes, in Markdown, with no preamble."

    static func user(template: String, recording: Recording, transcript: TranscriptResult) -> String {
        let date = recording.created.formatted(date: .abbreviated, time: .shortened)
        return template.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            + "Call: \(recording.title)\nDate: \(date)\nLength: \(formatTime(recording.duration))\n"
            + "Language: \(recording.callLanguage.title)\n\n"
            + "<transcript>\n\(transcript.text)\n</transcript>"
    }

    /// Rough token count for sizing a local model's context: about 3 characters per token for romanised
    /// Hinglish and English, which errs on the large side.
    static func estimatedTokens(_ text: String) -> Int { text.count / 3 + 1 }
}

/// The best transcript to write notes from: Claude's review, then Gemini, ElevenLabs, Local.
func bestTranscript(_ r: Recording) -> TranscriptResult? {
    for k in [ProviderKind.claude, .claudeCode, .gemini, .elevenlabs, .local] {
        if let t = r.results.first(where: { $0.provider == k }) { return t }
    }
    return r.results.first
}

// MARK: - Ollama

struct OllamaModel: Identifiable, Hashable {
    let name: String
    let bytes: Int64
    var id: String { name }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// One line of Ollama's streamed /api/chat reply (newline-delimited JSON).
enum OllamaLine: Equatable {
    case text(String)
    /// The model is reasoning before it writes (thinking models such as qwen3). The reasoning itself is not kept.
    case thinking
    case done(reason: String?)
    case error(String)
    case ignore

    static func parse(_ line: String) -> OllamaLine {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignore }
        if let e = obj["error"] as? String { return .error(e) }
        if obj["done"] as? Bool == true { return .done(reason: obj["done_reason"] as? String) }
        // Thinking models also send message.thinking; only the answer is kept.
        if let m = obj["message"] as? [String: Any] {
            if let t = m["content"] as? String, !t.isEmpty { return .text(t) }
            if let t = m["thinking"] as? String, !t.isEmpty { return .thinking }
        }
        return .ignore
    }
}

struct OllamaClient {
    let base: URL

    init(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        base = URL(string: trimmed.isEmpty ? AppSettings.defaultOllamaURL : trimmed)
            ?? URL(string: AppSettings.defaultOllamaURL)!
    }

    private func request(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 10) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = timeout
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    static let notRunning = "Ollama is not running. Open the Ollama app, or run: ollama serve"

    /// Installed models, largest first.
    func models() async throws -> [OllamaModel] {
        do {
            let (data, resp) = try await URLSession.shared.data(for: request("api/tags"))
            try httpCheck(resp, data, who: "Ollama")
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let list = (obj?["models"] as? [[String: Any]]) ?? []
            return list.compactMap { m in
                guard let name = m["name"] as? String else { return nil }
                return OllamaModel(name: name, bytes: (m["size"] as? NSNumber)?.int64Value ?? 0)
            }
            .sorted { $0.bytes > $1.bytes }
        } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .timedOut || e.code == .networkConnectionLost {
            throw TranscribeError.message(Self.notRunning)
        }
    }

    /// The longest context the model supports, from /api/show ("<architecture>.context_length").
    func contextLength(_ model: String) async -> Int? {
        guard let req = try? request("api/show", body: ["model": model]),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["model_info"] as? [String: Any] else { return nil }
        for (k, v) in info where k.hasSuffix(".context_length") { return (v as? NSNumber)?.intValue }
        return nil
    }

    /// Streams the notes. Ollama's default context is only a few thousand tokens, which would silently cut a
    /// long transcript, so the context is sized to the prompt (and refused when the model cannot hold it).
    func write(model: String, system: String, user: String, onThinking: @escaping @Sendable () -> Void = {},
               onText: @escaping @Sendable (String) -> Void) async throws {
        let need = NotesPrompt.estimatedTokens(system + user) + 4096
        let maxCtx = await contextLength(model) ?? 32_768
        guard need <= maxCtx else {
            throw TranscribeError.message("This transcript is about \(need / 1000)K tokens, more than \(model) can read (\(maxCtx / 1000)K). Use Claude, or a local model with a larger context.")
        }
        let numCtx = min(maxCtx, max(8192, (need + 2047) / 2048 * 2048))
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "options": ["num_ctx": numCtx],
        ]
        let req = try request("api/chat", body: body, timeout: 3600)
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await URLSession.shared.bytes(for: req) } catch let e as URLError where e.code == .cannotConnectToHost {
            throw TranscribeError.message(Self.notRunning)
        }
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 400 { break } }
            if case .error(let e) = OllamaLine.parse(text) { throw TranscribeError.message("Ollama: \(e)") }
            throw TranscribeError.http(status: h.statusCode, text: "Ollama returned \(h.statusCode): \(text)")
        }
        for try await line in bytes.lines {
            switch OllamaLine.parse(line) {
            case .text(let t): onText(t)
            case .thinking: onThinking()
            case .error(let e): throw TranscribeError.message("Ollama: \(e)")
            case .done(let reason):
                if reason == "length" { onText("\n\n_(The notes were cut off: the model reached its length limit.)_") }
                return
            case .ignore: continue
            }
        }
    }
}

// MARK: - Claude Code

/// One line of `claude -p --output-format stream-json --include-partial-messages`.
enum ClaudeCodeLine: Equatable {
    case text(String)
    case stop(String)
    case result(isError: Bool, message: String)
    case ignore

    static func parse(_ line: String) -> ClaudeCodeLine {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignore }
        switch obj["type"] as? String {
        case "stream_event":
            guard let ev = obj["event"] as? [String: Any] else { return .ignore }
            switch ev["type"] as? String {
            case "content_block_delta":
                if let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                    return .text(t)
                }
            case "message_delta":
                if let d = ev["delta"] as? [String: Any], let r = d["stop_reason"] as? String { return .stop(r) }
            default: break
            }
        case "result":
            return .result(isError: obj["is_error"] as? Bool ?? false, message: obj["result"] as? String ?? "")
        default: break
        }
        return .ignore
    }
}

/// Runs one prompt through the Claude Code command line, so it uses the Claude subscription the user is
/// signed in to there, not an API key. Claude gets no tools, no MCP servers, no settings or CLAUDE.md
/// and the session is not saved: it only reads the prompt and writes text.
/// Used for meeting notes and for the Claude Code transcript review.
enum ClaudeCode {

    /// Where `claude` usually lives. Apps opened from Finder do not get the shell's PATH.
    nonisolated static func findBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static let notFound = "Claude Code is not installed. Install it from claude.com/claude-code, then run claude once in Terminal to sign in."

    static func run(model: String, system: String, user: String, onText: @escaping @Sendable (String) -> Void) async throws {
        guard let bin = Self.findBinary() else { throw TranscribeError.message(Self.notFound) }

        // An empty folder to run in, so no project's CLAUDE.md is picked up.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/claude-notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.currentDirectoryURL = dir
        p.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                       "--model", model, "--effort", "medium", "--system-prompt", system,
                       "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                       "--disable-slash-commands", "--no-session-persistence"]
        var env = ProcessInfo.processInfo.environment
        // A key in the environment would make Claude Code bill the API instead of the subscription.
        env["ANTHROPIC_API_KEY"] = nil
        env["ANTHROPIC_AUTH_TOKEN"] = nil
        // A reviewed transcript of a long call is long; leave room for it.
        env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "64000"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env

        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        let errLog = LineLog()
        errors.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errLog.append(String(decoding: d, as: UTF8.self)) }
        }

        try p.run()
        // The transcript goes through stdin: it is too long for an argument.
        let prompt = Data(user.utf8)
        DispatchQueue.global().async {
            try? input.fileHandleForWriting.write(contentsOf: prompt)
            try? input.fileHandleForWriting.close()
        }

        var result: (isError: Bool, message: String)?
        var stop = ""
        try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                switch ClaudeCodeLine.parse(line) {
                case .text(let t): onText(t)
                case .stop(let r): stop = r
                case .result(let e, let m): result = (e, m)
                case .ignore: continue
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        p.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()

        if let result, result.isError {
            throw TranscribeError.message("Claude Code: \(result.message.isEmpty ? "the request failed." : result.message)")
        }
        if result == nil {
            let tail = errLog.text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
            throw TranscribeError.message(tail.isEmpty
                ? "Claude Code stopped without writing notes (exit \(p.terminationStatus))."
                : "Claude Code: \(tail)")
        }
        if stop == "refusal" { throw TranscribeError.message("Claude declined this transcript.") }
        if stop == "max_tokens" { onText("\n\n_(The notes were cut off: Claude reached its length limit.)_") }
    }
}

/// Meeting notes through Claude Code.
struct ClaudeCodeNotes {
    let model: String
    static func findBinary() -> String? { ClaudeCode.findBinary() }
    static var notFound: String { ClaudeCode.notFound }
    func write(system: String, user: String, onText: @escaping @Sendable (String) -> Void) async throws {
        try await ClaudeCode.run(model: model, system: system, user: user, onText: onText)
    }
}

// MARK: - Runner

/// The streamed text, filled from the network task. The saved notes are read from here, so no piece
/// that is still on its way to the screen can be lost.
final class TextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) -> String { lock.lock(); defer { lock.unlock() }; text += s; return text }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

@MainActor
final class NotesRunner: ObservableObject {
    struct Job: Equatable {
        var engine: NotesEngineKind
        var model: String
        var phase: String
        var text = ""
        let started: Date
    }

    @Published private(set) var jobs: [String: Job] = [:]
    @Published private(set) var errors: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let store: RecordingStore
    private let settings: AppSettings

    init(store: RecordingStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func job(_ id: String) -> Job? { jobs[id] }
    func error(_ id: String) -> String? { errors[id] }
    func dismissError(_ id: String) { errors[id] = nil }

    func start(_ recording: Recording, transcript: TranscriptResult, engine: NotesEngineKind, model: String) {
        let id = recording.id
        guard jobs[id] == nil else { return }
        errors[id] = nil
        let started = Date()
        jobs[id] = Job(engine: engine, model: model, phase: engine == .ollama ? "Waiting for the local model" : "Sending to Claude Code",
                       started: started)
        let system = NotesPrompt.system
        let user = NotesPrompt.user(template: settings.notesTemplate, recording: recording, transcript: transcript)
        let ollama = OllamaClient(settings.ollamaURL)
        let claude = ClaudeCodeNotes(model: model)
        let buffer = TextBuffer()
        let onText: @Sendable (String) -> Void = { [weak self] t in
            let all = buffer.append(t)
            Task { @MainActor in
                guard let self, self.jobs[id]?.started == started else { return }
                self.jobs[id]?.text = all
                self.jobs[id]?.phase = "Writing"
            }
        }
        tasks[id] = Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                                 reason: "Writing meeting notes")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                switch engine {
                case .ollama:
                    // Shares the GPU with whisper: wait for any local transcription to finish first.
                    await LocalQueue.shared.acquire()
                    jobs[id]?.phase = "Reading the transcript"
                    do {
                        try await ollama.write(model: model, system: system, user: user, onThinking: { [weak self] in
                            Task { @MainActor in
                                guard let self, self.jobs[id]?.started == started, self.jobs[id]?.text.isEmpty == true else { return }
                                if self.jobs[id]?.phase != "Thinking" { self.jobs[id]?.phase = "Thinking" }
                            }
                        }, onText: onText)
                        await LocalQueue.shared.release()
                    } catch {
                        await LocalQueue.shared.release()
                        throw error
                    }
                case .claude:
                    try await claude.write(system: system, user: user, onText: onText)
                }
                try Task.checkCancellation()
                let text = buffer.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw TranscribeError.message("The model returned no notes.") }
                store.setNotes(MeetingNotes(engine: engine, model: model, source: transcript.provider, text: text,
                                            date: Date(), seconds: Date().timeIntervalSince(started)), for: id)
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                errors[id] = error.localizedDescription
            }
            if jobs[id]?.started == started { jobs[id] = nil }
            tasks[id] = nil
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs[id] = nil
    }
}
