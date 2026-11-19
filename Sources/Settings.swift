import Foundation
import Security

/// API keys live in the macOS Keychain, never in UserDefaults or on disk.
enum Keychain {
    static let service = "com.akshaybengani.scribe"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum OutputStyle: String, CaseIterable, Identifiable {
    case roman, devanagari
    var id: String { rawValue }
    var title: String {
        self == .roman ? "Hinglish in Roman script" : "Hindi in Devanagari, English in Latin"
    }
}

/// Plain values the background jobs need, so no UI object crosses threads.
struct Config: Sendable {
    var whisperPath: String
    var localModelPath: String
    var englishModelPath: String
    var language: String
    var hint: String
    var style: OutputStyle
    var geminiKey: String, geminiModel: String
    var elevenKey: String, elevenModel: String
    var claudeKey: String, claudeModel: String

    func localPath(_ lang: CallLanguage) -> String { lang == .english ? englishModelPath : localModelPath }

    func model(_ k: ProviderKind, _ lang: CallLanguage = .mixed) -> String {
        switch k {
        case .local: return URL(fileURLWithPath: localPath(lang)).deletingPathExtension().lastPathComponent
        case .gemini: return geminiModel
        case .elevenlabs: return elevenModel
        case .claude: return claudeModel
        }
    }
}

/// What the settings screen shows for one provider's fetched model list.
struct ModelCatalogState: Equatable {
    /// Result of the provider's list-models call (last good one; kept when a refresh fails).
    var fetched: [ModelInfo] = []
    var isLoading = false
    /// Plain-language reason the last refresh failed, nil when it worked or has not run.
    var error: String? = nil
    var lastRefreshed: Date? = nil
}

private struct ModelCache: Codable {
    var models: [ModelInfo]
    var fetchedAt: Date
}

@MainActor
final class AppSettings: ObservableObject {
    private let d: UserDefaults
    private let session: URLSession
    private var refreshGeneration: [ProviderKind: Int] = [:]
    private var debounce: [ProviderKind: Task<Void, Never>] = [:]

    static let defaultTemplate = """
    Below is a machine-generated transcript of a conversation that mixes Hindi and English. \
    It may contain recognition errors, so treat odd words as possible mistakes. \
    Turn it into clear notes: a short summary, decisions, action items with owners, and open questions.


    """

    @Published var primary: ProviderKind { didSet { d.set(primary.rawValue, forKey: "primary") } }
    @Published var captureSystemAudio: Bool { didSet { d.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    /// Off records computer audio only (for example a webinar). On by default.
    @Published var captureMicrophone: Bool { didSet { d.set(captureMicrophone, forKey: "captureMicrophone") } }

    @Published var whisperPath: String { didSet { d.set(whisperPath, forKey: "whisperPath") } }
    @Published var localModelPath: String { didSet { d.set(localModelPath, forKey: "localModelPath") } }
    @Published var englishModelPath: String { didSet { d.set(englishModelPath, forKey: "englishModelPath") } }
    /// The language chosen on the home page for new recordings; each recording remembers its own.
    @Published var callLanguage: CallLanguage { didSet { d.set(callLanguage.rawValue, forKey: "callLanguage") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var hint: String { didSet { d.set(hint, forKey: "hint") } }
    @Published var styleRaw: String { didSet { d.set(styleRaw, forKey: "style") } }
    @Published var template: String { didSet { d.set(template, forKey: "template") } }

    @Published var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }
    @Published var elevenModel: String { didSet { d.set(elevenModel, forKey: "elevenModel") } }
    @Published var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }

    @Published var geminiKey: String { didSet { Keychain.set(geminiKey, account: "gemini"); keyChanged(.gemini) } }
    @Published var elevenKey: String { didSet { Keychain.set(elevenKey, account: "elevenlabs"); keyChanged(.elevenlabs) } }
    @Published var claudeKey: String { didSet { Keychain.set(claudeKey, account: "claude"); keyChanged(.claude) } }

    /// Fetched model lists per cloud provider, with loading and error state. Read through
    /// `catalog(_:)` and `modelOptions(_:)`; `.local` never has an entry.
    @Published private(set) var catalogs: [ProviderKind: ModelCatalogState] = [:]

    var style: OutputStyle {
        get { OutputStyle(rawValue: styleRaw) ?? .roman }
        set { styleRaw = newValue.rawValue }
    }

    static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/Models", isDirectory: true)
    }

    /// One-time message after stored model names were moved to the new defaults; nil once dismissed.
    @Published private(set) var modelMigrationNote: String?

    /// Stored values equal to an old default are moved to the new default, once. Storage only gets a model
    /// name when the user edits the field, so an old-default value was typed or picked; there is no way to
    /// tell, so the change is announced in `modelMigrationNote` instead of being silent.
    static func migrateModelDefaults(_ d: UserDefaults) {
        let flag = "modelDefaults.migrated.2026-11-17"
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)
        var moved: [String] = []
        for (kind, field) in [(ProviderKind.gemini, "geminiModel"), (.elevenlabs, "elevenModel")] {
            guard let old = ModelCatalog.retiredDefaults[kind], d.string(forKey: field) == old else { continue }
            let new = ModelCatalog.defaultModel(kind)
            d.set(new, forKey: field)
            moved.append("\(kind.short): \(old) to \(new)")
        }
        if !moved.isEmpty {
            d.set("Model names were updated to the current defaults (" + moved.joined(separator: "; ")
                  + "). You can change them in AI Models.", forKey: "modelMigrationNote")
        }
    }

    func dismissModelMigrationNote() {
        d.removeObject(forKey: "modelMigrationNote")
        modelMigrationNote = nil
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        d = defaults
        self.session = session
        Self.migrateModelDefaults(defaults)
        primary = ProviderKind(rawValue: d.string(forKey: "primary") ?? "") ?? .local
        captureSystemAudio = d.bool(forKey: "captureSystemAudio")
        captureMicrophone = d.object(forKey: "captureMicrophone") as? Bool ?? true
        let detected = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli"
        whisperPath = d.string(forKey: "whisperPath") ?? detected
        localModelPath = d.string(forKey: "localModelPath")
            ?? Self.modelsFolder.appendingPathComponent("ggml-oriserve-f16.bin").path
        // English-only calls default to Whisper large-v3-turbo (q5_0), the pick from the English bake-off.
        // Only used when no path has been saved.
        englishModelPath = d.string(forKey: "englishModelPath")
            ?? Self.modelsFolder.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path
        callLanguage = CallLanguage(rawValue: d.string(forKey: "callLanguage") ?? "") ?? .mixed
        language = d.string(forKey: "language") ?? "en"
        hint = d.string(forKey: "hint") ?? ""
        styleRaw = d.string(forKey: "style") ?? OutputStyle.roman.rawValue
        template = d.string(forKey: "template") ?? Self.defaultTemplate
        // Defaults are current model names (see ModelCatalog); a saved value always wins.
        geminiModel = d.string(forKey: "geminiModel") ?? ModelCatalog.defaultModel(.gemini)
        elevenModel = d.string(forKey: "elevenModel") ?? ModelCatalog.defaultModel(.elevenlabs)
        claudeModel = d.string(forKey: "claudeModel") ?? ModelCatalog.defaultModel(.claude)
        geminiKey = Keychain.get("gemini")
        elevenKey = Keychain.get("elevenlabs")
        claudeKey = Keychain.get("claude")
        modelMigrationNote = d.string(forKey: "modelMigrationNote")
        for k in Self.cloudKinds { if let c = loadCache(k) { catalogs[k] = ModelCatalogState(fetched: c.models, lastRefreshed: c.fetchedAt) } }
    }

    // MARK: - Model catalogs

    static let cloudKinds: [ProviderKind] = [.gemini, .elevenlabs, .claude]
    /// A cached list older than this is refreshed by `refreshStaleModels()`.
    nonisolated static let modelCacheMaxAge: TimeInterval = 24 * 3600

    func catalog(_ k: ProviderKind) -> ModelCatalogState { catalogs[k] ?? ModelCatalogState() }

    func apiKey(_ k: ProviderKind) -> String {
        switch k {
        case .gemini: return geminiKey
        case .elevenlabs: return elevenKey
        case .claude: return claudeKey
        case .local: return ""
        }
    }

    func selectedModel(_ k: ProviderKind) -> String {
        switch k {
        case .gemini: return geminiModel
        case .elevenlabs: return elevenModel
        case .claude: return claudeModel
        case .local: return ""
        }
    }

    func setModel(_ k: ProviderKind, _ id: String) {
        switch k {
        case .gemini: geminiModel = id
        case .elevenlabs: elevenModel = id
        case .claude: claudeModel = id
        case .local: break
        }
    }

    /// Curated plus fetched models, de-duplicated, audio-capable first then newest first. The model
    /// currently typed into the field is included even when no list knows it, so free-text names
    /// keep working and stay visible in a picker.
    func modelOptions(_ k: ProviderKind) -> [ModelInfo] {
        guard k != .local else { return [] }
        var list = ModelCatalog.merge(curated: ModelCatalog.curated(k), fetched: catalog(k).fetched)
        let current = selectedModel(k).trimmingCharacters(in: .whitespaces)
        if !current.isEmpty, !list.contains(where: { $0.id == current }) {
            list.insert(ModelCatalog.custom(k, id: current), at: 0)
        }
        return list
    }

    /// Only the audio-capable options, for a "transcription model" picker.
    func audioModelOptions(_ k: ProviderKind) -> [ModelInfo] { modelOptions(k).filter(\.supportsAudio) }

    /// A warning when the chosen Gemini or ElevenLabs model is known not to take audio; nil otherwise.
    /// Claude is a text reviewer, so it never warns.
    func modelWarning(_ k: ProviderKind) -> String? {
        guard k == .gemini || k == .elevenlabs else { return nil }
        let id = selectedModel(k).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let m = modelOptions(k).first(where: { $0.id == id }), !m.supportsAudio else { return nil }
        return "\(id) does not look like an audio transcription model. \(m.note)"
    }

    /// Calls the provider's list-models API and updates `catalogs[k]`. A failure keeps the previous list
    /// and sets `error`. A newer refresh for the same provider supersedes an older one still in flight.
    /// `key` overrides the stored key (used by tests, and to try a key before it is saved).
    func refreshModels(_ k: ProviderKind, key override: String? = nil) async {
        guard k != .local else { return }
        let key = (override ?? apiKey(k)).trimmingCharacters(in: .whitespacesAndNewlines)
        var state = catalog(k)
        guard !key.isEmpty else {
            refreshGeneration[k, default: 0] += 1
            state.isLoading = false
            state.error = nil
            catalogs[k] = state
            return
        }
        let gen = (refreshGeneration[k] ?? 0) + 1
        refreshGeneration[k] = gen
        state.isLoading = true
        state.error = nil
        catalogs[k] = state
        do {
            let list = try await ModelCatalog.fetch(kind: k, key: key, session: session)
            guard refreshGeneration[k] == gen else { return }
            let now = Date()
            catalogs[k] = ModelCatalogState(fetched: list, isLoading: false, error: nil, lastRefreshed: now)
            saveCache(k, ModelCache(models: list, fetchedAt: now))
        } catch {
            guard refreshGeneration[k] == gen else { return }
            var s = catalog(k)
            s.isLoading = false
            // A cancelled task (view went away) is not a failure worth showing.
            s.error = (error is CancellationError || (error as? URLError)?.code == .cancelled) ? nil
                : (error.localizedDescription)
            catalogs[k] = s
        }
    }

    /// Refreshes every cloud provider that has a key and no list, or a list older than `maxAge`.
    func refreshStaleModels(maxAge: TimeInterval = AppSettings.modelCacheMaxAge) async {
        for k in Self.cloudKinds {
            guard !apiKey(k).trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let t = catalog(k).lastRefreshed, Date().timeIntervalSince(t) < maxAge { continue }
            await refreshModels(k)
        }
    }

    /// Called when a key field changes. Waits for typing to pause, then refreshes (or clears the error
    /// when the key was emptied). Replaces any pending refresh for that provider.
    func keyChanged(_ k: ProviderKind, delay: Duration = .milliseconds(900)) {
        debounce[k]?.cancel()
        debounce[k] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.refreshModels(k)
        }
    }

    private func cacheKey(_ k: ProviderKind) -> String { "modelCache.\(k.rawValue)" }

    private func saveCache(_ k: ProviderKind, _ c: ModelCache) {
        if let data = try? JSONEncoder().encode(c) { d.set(data, forKey: cacheKey(k)) }
    }

    private func loadCache(_ k: ProviderKind) -> ModelCache? {
        guard let data = d.data(forKey: cacheKey(k)) else { return nil }
        return try? JSONDecoder().decode(ModelCache.self, from: data)
    }

    func config() -> Config {
        Config(whisperPath: whisperPath, localModelPath: localModelPath, englishModelPath: englishModelPath,
               language: language, hint: hint, style: style,
               geminiKey: geminiKey, geminiModel: geminiModel,
               elevenKey: elevenKey, elevenModel: elevenModel,
               claudeKey: claudeKey, claudeModel: claudeModel)
    }

    func name(_ k: ProviderKind, language: CallLanguage? = nil) -> String {
        let model = config().model(k, language ?? callLanguage)
        return model.isEmpty ? k.short : "\(k.short) · \(model)"
    }

    /// nil when the provider is ready to use, otherwise a plain-language reason.
    func issue(for k: ProviderKind, language: CallLanguage? = nil) -> String? {
        switch k {
        case .local:
            if !FileManager.default.isExecutableFile(atPath: whisperPath) {
                return "whisper-cli was not found at \(whisperPath). Install it with: brew install whisper-cpp"
            }
            let path = config().localPath(language ?? callLanguage)
            if !FileManager.default.fileExists(atPath: path) {
                return "The local model file is missing: \(path)"
            }
            return nil
        case .gemini: return cloudIssue(geminiKey, geminiModel, "Gemini")
        case .elevenlabs: return cloudIssue(elevenKey, elevenModel, "ElevenLabs")
        case .claude: return cloudIssue(claudeKey, claudeModel, "Claude")
        }
    }

    private func cloudIssue(_ key: String, _ model: String, _ name: String) -> String? {
        if key.trimmingCharacters(in: .whitespaces).isEmpty { return "No \(name) API key yet. Add it in AI Models." }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "No \(name) model name yet. Add it in AI Models." }
        return nil
    }
}
