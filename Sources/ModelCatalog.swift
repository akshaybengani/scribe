import Foundation

// MARK: - Model catalog
//
// Curated "known good" model names per provider, plus a fetcher for each provider's
// list-models API. Verified against the providers' own docs on 16 Nov 2026:
//
// Gemini  (https://aistudio.google.com/api-reference/models/list-models, redirected from ai.google.dev)
//   GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=N&pageToken=T
//   Response { models: [Model], nextPageToken? }. Default pageSize 50, server caps at 1000.
//   Model.name is "models/<id>"; also baseModelId, version, displayName, description,
//   inputTokenLimit, outputTokenLimit, supportedGenerationMethods. The docs show the key as a
//   ?key= query parameter; the x-goog-api-key header is what Providers.swift already uses for
//   generateContent, so the same header is used here (not separately documented on the list page).
//   Model pages (aistudio.google.com/docs/models/...): gemini-3.8-flash is the newest stable Flash and
//   lists Audio input; gemini-3.6-flash lists Audio; gemini-4-hydrogen/argon/carbon list Audio.
//   Gemini 2.5 models are marked deprecated. TTS, Live/native-audio, image, embedding and video
//   models are separate ids (and Live ones only support bidiGenerateContent).
//
// ElevenLabs (https://elevenlabs.io/docs/api-reference/models/list, /docs/overview/models)
//   GET https://api.elevenlabs.io/v1/models with header xi-api-key. Response is a bare JSON array of
//   { model_id, name, description, can_do_text_to_speech, can_do_voice_conversion, languages, ... }.
//   The docs describe only text-to-speech/voice-conversion flags and do not say speech-to-text models
//   appear, so the curated Scribe list is always merged in.
//   Scribe models: scribe_v3 (current batch flagship, "27% fewer word errors than v2", adds
//   secondary_language_codes for mixed-language audio), scribe_v2 (previous flagship),
//   scribe_v2_medical, scribe_v1 (deprecated). scribe_v2_realtime and scribe_v3_live are
//   WebSocket-only and not usable with POST /v1/speech-to-text, so they are not offered.
//
// Anthropic (https://platform.claude.com/docs/en/api/models/list)
//   GET https://api.anthropic.com/v1/models?limit=N&after_id=ID. Response
//   { data: [{ id, display_name, created_at, lifecycle, ... }], has_more, first_id, last_id }.
//   limit 1..1000, default 20, newest first. Docs say x-api-key is the "legacy fallback, still supported"
//   next to Authorization: Bearer; the anthropic-version header is required (docs now show 2026-10-21;
//   2023-06-01 is still listed as a valid version, and is what Providers.swift sends).
//   Retired models are only returned when asked for; we never ask. Claude is text only: no audio.

struct ModelInfo: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
    /// True when the model can take audio as input and turn it into a transcript.
    var supportsAudio: Bool
    var note: String
    /// Release date when the provider reports one (Anthropic); otherwise nil and the version in the id is used.
    var released: Date? = nil

    /// The model can label who is speaking in its transcript. Derived from the id (not stored), so
    /// lists cached by an older build still carry it.
    var speakerLabels: Bool { ModelCatalog.speakerLabelModels.contains(id) }
    /// Longest recording, in minutes, the model accepts when speaker labels are on; nil when no such cap is documented.
    var maxMinutesWithSpeakers: Int? { ModelCatalog.speakerMinuteCaps[id] }

    init(id: String, displayName: String? = nil, supportsAudio: Bool, note: String = "", released: Date? = nil) {
        self.id = id
        self.displayName = (displayName?.isEmpty == false) ? displayName! : id
        self.supportsAudio = supportsAudio
        self.note = note
        self.released = released
    }
}

enum ModelCatalogError: LocalizedError {
    case unsupported
    case noKey
    case http(String, Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This provider has no model list."
        case .noKey: return "Add an API key first."
        case .http(let who, let code, let msg):
            if code == 401 || code == 403 {
                return "\(who) rejected the API key (HTTP \(code))." + (msg.isEmpty ? "" : " \(msg)")
            }
            return "\(who) returned HTTP \(code)." + (msg.isEmpty ? "" : " \(msg)")
        case .badResponse(let who): return "\(who) sent a model list Scribe could not read."
        }
    }
}

enum ModelCatalog {
    // MARK: Curated lists (best first; the sort below keeps this order's spirit)

    static func curated(_ kind: ProviderKind) -> [ModelInfo] {
        switch kind {
        case .local: return []
        case .gemini:
            let assumed = "Audio input assumed (the docs list its inputs only for newer Flash models)."
            return [
                ModelInfo(id: "gemini-3.5-transcribe", displayName: "Gemini 3.5 Transcribe", supportsAudio: true,
                          note: "Dedicated speech model, speaker labels, 85+ languages incl. Hindi and English India, code-switching. Default."),
                ModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", supportsAudio: true,
                          note: "General model, older. Deprecated by Google for new projects."),
                ModelInfo(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash", supportsAudio: true,
                          note: "Newest stable Flash. Audio input confirmed in the docs."),
                ModelInfo(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash", supportsAudio: true,
                          note: "Previous generation, audio input confirmed."),
                ModelInfo(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash-Lite", supportsAudio: true, note: assumed),
                ModelInfo(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash-Lite", supportsAudio: true, note: assumed),
                ModelInfo(id: "gemini-4-hydrogen", displayName: "Gemini 4 Hydrogen", supportsAudio: true,
                          note: "Gemini 4 family, audio input confirmed. Pricing tier not checked."),
                ModelInfo(id: "gemini-4-argon", displayName: "Gemini 4 Argon", supportsAudio: true,
                          note: "Gemini 4 family, audio input confirmed. Pricing tier not checked."),
                ModelInfo(id: "gemini-4-carbon", displayName: "Gemini 4 Carbon", supportsAudio: true,
                          note: "Gemini 4 family, audio input confirmed. Pricing tier not checked."),
                ModelInfo(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro (preview)", supportsAudio: true, note: assumed),
            ]
        case .elevenlabs:
            return [
                ModelInfo(id: "scribe_v2", displayName: "Scribe v2", supportsAudio: true,
                          note: "Batch speech to text with speaker labels. Default."),
                ModelInfo(id: "scribe_v1", displayName: "Scribe v1", supportsAudio: true,
                          note: "First generation, still accepted; ElevenLabs lists it as deprecated."),
                ModelInfo(id: "scribe_v3", displayName: "Scribe v3", supportsAudio: true,
                          note: "Newer batch model per the ElevenLabs models page; adds mixed-language options."),
                ModelInfo(id: "scribe_v2_medical", displayName: "Scribe v2 Medical", supportsAudio: true,
                          note: "Fine-tuned for clinical audio; same as v2 on everyday speech."),
            ]
        case .claude:
            return [
                ModelInfo(id: "claude-fable-5-2", displayName: "Claude Fable 5.2", supportsAudio: false, note: "Text only."),
                ModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", supportsAudio: false, note: "Text only."),
                ModelInfo(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", supportsAudio: false,
                          note: "Text only. Default for note review."),
                ModelInfo(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", supportsAudio: false, note: "Text only. Fastest."),
            ]
        }
    }

    /// The model name a fresh install starts with.
    static func defaultModel(_ kind: ProviderKind) -> String {
        switch kind {
        case .local: return ""
        case .gemini: return "gemini-3.5-transcribe"
        case .elevenlabs: return "scribe_v2"
        case .claude: return "claude-sonnet-5-5"
        }
    }

    /// Defaults a previous build shipped. A stored value equal to one of these is moved to the new default once.
    static let retiredDefaults: [ProviderKind: String] = [.gemini: "gemini-2.5-flash", .elevenlabs: "scribe_v1"]

    /// Models that can label speakers. gemini-3.5-transcribe (diarization, per its docs) and the Scribe
    /// batch models (diarize=true is what ElevenLabsTranscriber sends; Scribe v3 documents up to 32 speakers).
    static let speakerLabelModels: Set<String> = ["gemini-3.5-transcribe", "scribe_v2", "scribe_v3"]
    /// gemini-3.5-transcribe takes up to 1 hour per request, 30 minutes with diarization or word timestamps.
    static let speakerMinuteCaps: [String: Int] = ["gemini-3.5-transcribe": 30]

    /// Pinned models sort above the rest of their audio group (higher first): the recommended pick, then its fallback.
    static let pins: [String: Int] = ["gemini-3.5-transcribe": 100, "gemini-2.5-flash": 90, "scribe_v2": 100, "scribe_v1": 90]

    // MARK: Merge and sort

    /// De-duplicates by id (fetched data wins over curated, but a curated note is kept when the
    /// fetched entry has none) and returns audio-capable models first, then newest first.
    static func merge(curated: [ModelInfo], fetched: [ModelInfo]) -> [ModelInfo] {
        var byID: [String: ModelInfo] = [:]
        for m in curated { byID[m.id] = m }
        for m in fetched {
            if var old = byID[m.id] {
                var new = m
                if new.note.isEmpty { new.note = old.note }
                // A curated "audio" call is based on the docs; the fetched flag is only a heuristic,
                // so audio true from either side wins.
                new.supportsAudio = new.supportsAudio || old.supportsAudio
                if new.released == nil { new.released = old.released }
                if new.displayName == new.id, old.displayName != old.id { new.displayName = old.displayName }
                old = new
                byID[m.id] = old
            } else {
                byID[m.id] = m
            }
        }
        return sorted(Array(byID.values))
    }

    static func sorted(_ models: [ModelInfo]) -> [ModelInfo] {
        models.sorted { a, b in
            if a.supportsAudio != b.supportsAudio { return a.supportsAudio }
            let pa0 = pins[a.id] ?? 0, pb0 = pins[b.id] ?? 0
            if pa0 != pb0 { return pa0 > pb0 }
            let da = a.released ?? .distantPast, db = b.released ?? .distantPast
            if da != db { return da > db }
            let va = versionKey(a.id), vb = versionKey(b.id)
            if va != vb { return lexLess(vb, va) }          // higher version first
            let pa = isPrerelease(a.id), pb = isPrerelease(b.id)
            if pa != pb { return !pa }                        // stable before preview
            return a.id < b.id
        }
    }

    /// Major and optional minor version from an id: "gemini-3.8-flash" -> [3,8], "scribe_v3" -> [3],
    /// "claude-opus-5-5" -> [5,5], "claude-3-5-sonnet-20241022" -> [3,5], "claude-sonnet-4-20250514" -> [4].
    /// A minor is a separator (. or -) plus at most two digits, so dates are never read as versions.
    static func versionKey(_ id: String) -> [Int] {
        let chars = Array(id)
        var i = 0
        while i < chars.count, !chars[i].isNumber { i += 1 }
        func run(_ start: Int) -> (String, Int) {
            var j = start, s = ""
            while j < chars.count, chars[j].isNumber { s.append(chars[j]); j += 1 }
            return (s, j)
        }
        let (major, end) = run(i)
        guard !major.isEmpty else { return [] }
        var out = [Int(major) ?? 0]
        if end + 1 < chars.count, chars[end] == "." || chars[end] == "-", chars[end + 1].isNumber {
            let (minor, _) = run(end + 1)
            if minor.count <= 2 { out.append(Int(minor) ?? 0) }
        }
        return out
    }

    private static func lexLess(_ a: [Int], _ b: [Int]) -> Bool {
        for k in 0..<min(a.count, b.count) where a[k] != b[k] { return a[k] < b[k] }
        return a.count < b.count
    }

    private static func isPrerelease(_ id: String) -> Bool {
        let s = id.lowercased()
        return s.contains("preview") || s.contains("-exp") || s.contains("experimental") || s.hasSuffix("-latest")
    }

    /// An entry for a model name the user typed that no list knows, with audio guessed from the name.
    static func custom(_ kind: ProviderKind, id: String) -> ModelInfo {
        let audio: Bool
        switch kind {
        // Unknown names get the benefit of the doubt (a tuned or new model); only names that match a
        // known non-transcription family are flagged.
        case .gemini: audio = !geminiExcluded(id)
        case .elevenlabs: audio = !id.hasPrefix("eleven_") && !id.contains("realtime") && !id.contains("_live")
        case .claude, .local: audio = false
        }
        return ModelInfo(id: id, displayName: id, supportsAudio: audio, note: "Custom name, not in the list.")
    }

    // MARK: Fetch

    /// Calls the provider's list-models API. Pass a stubbed `session` in tests.
    static func fetch(kind: ProviderKind, key: String, session: URLSession = .shared) async throws -> [ModelInfo] {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ModelCatalogError.noKey }
        switch kind {
        case .local: throw ModelCatalogError.unsupported
        case .gemini: return sorted(try await fetchGemini(key: key, session: session))
        case .elevenlabs:
            let fetched = try await fetchElevenLabs(key: key, session: session)
            return merge(curated: curated(.elevenlabs), fetched: fetched)
        case .claude: return sorted(try await fetchClaude(key: key, session: session))
        }
    }

    private static let maxPages = 20

    private static func get(_ url: URL, headers: [String: String], who: String, session: URLSession) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ModelCatalogError.badResponse(who) }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelCatalogError.http(who, http.statusCode, errorMessage(data))
        }
        return data
    }

    /// Pulls a short message out of the common error envelopes ({"error":{"message"}}, {"detail":{"message"}}, ...).
    static func errorMessage(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let d = obj["detail"] as? [String: Any], let m = d["message"] as? String { return m }
        if let d = obj["detail"] as? String { return d }
        if let m = obj["message"] as? String { return m }
        return ""
    }

    // Gemini

    static func fetchGemini(key: String, session: URLSession) async throws -> [ModelInfo] {
        var out: [ModelInfo] = []
        var token: String? = nil
        for _ in 0..<maxPages {
            var c = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            var q = [URLQueryItem(name: "pageSize", value: "1000")]
            if let t = token { q.append(URLQueryItem(name: "pageToken", value: t)) }
            c.queryItems = q
            let data = try await get(c.url!, headers: ["x-goog-api-key": key], who: "Gemini", session: session)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ModelCatalogError.badResponse("Gemini")
            }
            for m in (obj["models"] as? [[String: Any]]) ?? [] {
                if let info = parseGemini(m) { out.append(info) }
            }
            token = obj["nextPageToken"] as? String
            if token == nil || token!.isEmpty { break }
        }
        return out
    }

    /// Keeps only models that can be used with generateContent (drops embedding-only, Live-only,
    /// predict-only models) and flags audio input.
    static func parseGemini(_ m: [String: Any]) -> ModelInfo? {
        guard var id = m["name"] as? String else { return nil }
        if id.hasPrefix("models/") { id.removeFirst("models/".count) }
        let methods = (m["supportedGenerationMethods"] as? [String]) ?? []
        guard methods.contains("generateContent") else { return nil }
        let name = (m["displayName"] as? String) ?? id
        let audio = geminiAcceptsAudio(id: id)
        var note = ""
        let desc = (m["description"] as? String) ?? ""
        if !audio { note = geminiExclusionNote(id) }
        else if id.contains("transcribe") { note = "Dedicated speech model with speaker labels." }
        else if !desc.isEmpty { note = String(desc.prefix(140)) }
        return ModelInfo(id: id, displayName: name, supportsAudio: audio, note: note)
    }

    private static let geminiNonAudio = ["embedding", "embed", "imagen", "image", "veo", "video", "omni", "tts",
                                         "live", "native-audio", "aqa", "gemma", "learnlm", "robotics", "computer-use"]

    /// Audio input is flagged for Gemini-family text models; Google's list API has no per-modality field,
    /// so this is a name heuristic: a "gemini*" model that supports generateContent and is not an
    /// embedding, image, video, text-to-speech or Live/native-audio variant.
    static func geminiAcceptsAudio(id: String) -> Bool {
        let s = id.lowercased()
        return s.hasPrefix("gemini") && !geminiExcluded(id)
    }

    static func geminiExcluded(_ id: String) -> Bool {
        let s = id.lowercased()
        return geminiNonAudio.contains { s.contains($0) }
    }

    private static func geminiExclusionNote(_ id: String) -> String {
        let s = id.lowercased()
        if s.contains("tts") { return "Text to speech, cannot transcribe." }
        if s.contains("image") || s.contains("imagen") { return "Image model." }
        if s.contains("embed") { return "Embedding model." }
        if s.contains("veo") || s.contains("video") || s.contains("omni") { return "Video model." }
        if s.contains("live") || s.contains("native-audio") { return "Live audio model, not for file transcription." }
        if !s.hasPrefix("gemini") { return "Not a Gemini model; audio input not assumed." }
        return "Not used for audio transcription."
    }

    // ElevenLabs

    static func fetchElevenLabs(key: String, session: URLSession) async throws -> [ModelInfo] {
        let data = try await get(URL(string: "https://api.elevenlabs.io/v1/models")!,
                                 headers: ["xi-api-key": key], who: "ElevenLabs", session: session)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ModelCatalogError.badResponse("ElevenLabs")
        }
        return arr.compactMap(parseElevenLabs)
    }

    static func parseElevenLabs(_ m: [String: Any]) -> ModelInfo? {
        guard let id = m["model_id"] as? String, !id.isEmpty else { return nil }
        let name = (m["name"] as? String) ?? id
        // Scribe models carry no can_do_* flag in the documented schema, so match on the id.
        let isSTT = id.hasPrefix("scribe") && !id.contains("realtime") && !id.contains("_live")
        let note: String
        if isSTT { note = "Speech to text." }
        else if id.hasPrefix("scribe") { note = "Streaming only, not usable for file transcription." }
        else if (m["can_do_text_to_speech"] as? Bool) == true { note = "Text to speech, cannot transcribe." }
        else { note = "Not a transcription model." }
        return ModelInfo(id: id, displayName: name, supportsAudio: isSTT, note: note)
    }

    // Anthropic

    static func fetchClaude(key: String, session: URLSession) async throws -> [ModelInfo] {
        var out: [ModelInfo] = []
        var after: String? = nil
        for _ in 0..<maxPages {
            var c = URLComponents(string: "https://api.anthropic.com/v1/models")!
            var q = [URLQueryItem(name: "limit", value: "1000")]
            if let a = after { q.append(URLQueryItem(name: "after_id", value: a)) }
            c.queryItems = q
            let data = try await get(c.url!, headers: ["x-api-key": key, "anthropic-version": "2023-06-01"],
                                     who: "Anthropic", session: session)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ModelCatalogError.badResponse("Anthropic")
            }
            for m in (obj["data"] as? [[String: Any]]) ?? [] {
                if let info = parseClaude(m) { out.append(info) }
            }
            let more = (obj["has_more"] as? Bool) ?? false
            after = obj["last_id"] as? String
            if !more || after == nil { break }
        }
        return out
    }

    static func parseClaude(_ m: [String: Any]) -> ModelInfo? {
        guard let id = m["id"] as? String, !id.isEmpty else { return nil }
        if (m["lifecycle"] as? String) == "retired" { return nil }
        let name = (m["display_name"] as? String) ?? id
        var note = "Text only."
        if (m["lifecycle"] as? String) == "deprecated" { note = "Text only. Deprecated by Anthropic." }
        return ModelInfo(id: id, displayName: name, supportsAudio: false, note: note,
                         released: (m["created_at"] as? String).flatMap(parseDate))
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
