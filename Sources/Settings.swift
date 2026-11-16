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

@MainActor
final class AppSettings: ObservableObject {
    private let d: UserDefaults

    static let defaultTemplate = """
    Below is a machine-generated transcript of a conversation that mixes Hindi and English. \
    It may contain recognition errors, so treat odd words as possible mistakes. \
    Turn it into clear notes: a short summary, decisions, action items with owners, and open questions.


    """

    @Published var primary: ProviderKind { didSet { d.set(primary.rawValue, forKey: "primary") } }
    @Published var captureSystemAudio: Bool { didSet { d.set(captureSystemAudio, forKey: "captureSystemAudio") } }

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

    @Published var geminiKey: String { didSet { Keychain.set(geminiKey, account: "gemini") } }
    @Published var elevenKey: String { didSet { Keychain.set(elevenKey, account: "elevenlabs") } }
    @Published var claudeKey: String { didSet { Keychain.set(claudeKey, account: "claude") } }

    var style: OutputStyle {
        get { OutputStyle(rawValue: styleRaw) ?? .roman }
        set { styleRaw = newValue.rawValue }
    }

    static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/Models", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        primary = ProviderKind(rawValue: d.string(forKey: "primary") ?? "") ?? .local
        captureSystemAudio = d.bool(forKey: "captureSystemAudio")
        let detected = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli"
        whisperPath = d.string(forKey: "whisperPath") ?? detected
        localModelPath = d.string(forKey: "localModelPath")
            ?? Self.modelsFolder.appendingPathComponent("ggml-oriserve-f16.bin").path
        // English-only calls default to the full Whisper large-v3, which is already strong at English.
        // Swap in an English-specific model (for example a .en or distil build) in AI Models.
        englishModelPath = d.string(forKey: "englishModelPath")
            ?? Self.modelsFolder.appendingPathComponent("ggml-large-v3-f16.bin").path
        callLanguage = CallLanguage(rawValue: d.string(forKey: "callLanguage") ?? "") ?? .mixed
        language = d.string(forKey: "language") ?? "en"
        hint = d.string(forKey: "hint") ?? ""
        styleRaw = d.string(forKey: "style") ?? OutputStyle.roman.rawValue
        template = d.string(forKey: "template") ?? Self.defaultTemplate
        // Defaults are real, working model names; change them to whichever you use.
        geminiModel = d.string(forKey: "geminiModel") ?? "gemini-2.5-flash"
        elevenModel = d.string(forKey: "elevenModel") ?? "scribe_v1"
        claudeModel = d.string(forKey: "claudeModel") ?? "claude-sonnet-5-5"
        geminiKey = Keychain.get("gemini")
        elevenKey = Keychain.get("elevenlabs")
        claudeKey = Keychain.get("claude")
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
