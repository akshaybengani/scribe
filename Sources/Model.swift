import Foundation
import AVFoundation

/// Who can produce a transcript. Claude is text-only: it reads existing
/// transcripts and returns a reviewed one, because it cannot take audio. Claude Code does the same
/// review through the Claude Code command line, on the user's Claude subscription instead of an API key.
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case local, gemini, elevenlabs, claude, claudeCode

    var id: String { rawValue }

    var short: String {
        switch self {
        case .local: return "Local"
        case .gemini: return "Gemini"
        case .elevenlabs: return "ElevenLabs"
        case .claude: return "Claude"
        case .claudeCode: return "Claude Code"
        }
    }

    var title: String {
        switch self {
        case .local: return "Local, on this Mac"
        case .gemini: return "Google Gemini"
        case .elevenlabs: return "ElevenLabs Scribe"
        case .claude: return "Anthropic Claude (text review)"
        case .claudeCode: return "Claude Code (text review, subscription)"
        }
    }

    var company: String {
        switch self {
        case .local: return "this Mac"
        case .gemini: return "Google"
        case .elevenlabs: return "ElevenLabs"
        case .claude, .claudeCode: return "Anthropic"
        }
    }

    var isCloud: Bool { self != .local }
    /// Claude only reads text, so it can never be the first transcriber.
    var hearsAudio: Bool { self != .claude && self != .claudeCode }
}

/// What the speakers use. English-only calls use English-specific models and prompts;
/// Hindi + English (Hinglish) uses the code-switching model.
enum CallLanguage: String, Codable, CaseIterable, Identifiable {
    case mixed, english
    var id: String { rawValue }
    var title: String { self == .mixed ? "Hindi + English" : "English only" }
}

enum FolderColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray
    var id: String { rawValue }
}

/// Folders nest to any depth. A recording sits in at most one folder; none means the top level.
struct Folder: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var color: FolderColor
    var parentID: String?
    var created: Date
}

struct TranscriptResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var provider: ProviderKind
    var modelName: String
    var text: String
    var seconds: Double
    var date: Date

    var tabTitle: String { provider == .local ? "Local" : provider.short }
}

struct Recording: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var created: Date
    var duration: Double
    var audioFile: String
    var results: [TranscriptResult]
    /// Optional so recordings saved before this option existed still load (they are Hinglish).
    var language: CallLanguage?
    /// nil = top level. Optional so recordings saved before folders existed still load.
    var folderID: String?
    /// Meeting notes written from a transcript. Optional so older recordings still load.
    var notes: MeetingNotes?

    var callLanguage: CallLanguage { language ?? .mixed }
}

/// Who writes meeting notes. Ollama runs on this Mac; Claude reads the transcript text at Anthropic,
/// through the Claude Code sign-in on this Mac.
enum NotesEngineKind: String, Codable, CaseIterable, Identifiable {
    case ollama, claude
    var id: String { rawValue }
    var title: String { self == .ollama ? "Local (Ollama)" : "Claude Code" }
    var isCloud: Bool { self == .claude }

    /// Claude Code model names. Claude Code turns each into its current model.
    static let claudeCodeModels: [(id: String, name: String)] = [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
}

/// Notes for one recording, in Markdown. Regenerating replaces them.
struct MeetingNotes: Codable, Equatable {
    var engine: NotesEngineKind
    var model: String
    /// The transcript tab the notes were written from.
    var source: ProviderKind
    var text: String
    var date: Date
    var seconds: Double
}

/// One folder per recording under Application Support/Scribe/Recordings/<id>/
/// holding the audio and meta.json. Everything stays on this Mac.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var folders: [Folder] = []
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Scribe/Recordings", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        load()
        loadFolders()
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func audioURL(for r: Recording) -> URL { folder(for: r.id).appendingPathComponent(r.audioFile) }

    /// Where a new recording's audio should be written. Creates the folder.
    func newAudioURL(id: String, ext: String) -> URL {
        let dir = folder(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audio.\(ext)")
    }

    private func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [Recording] = []
        for d in dirs {
            let meta = d.appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: meta), let r = try? decoder.decode(Recording.self, from: data) {
                out.append(r)
            }
        }
        recordings = out.sorted { $0.created > $1.created }
    }

    private func save(_ r: Recording) {
        let meta = folder(for: r.id).appendingPathComponent("meta.json")
        if let data = try? encoder.encode(r) { try? data.write(to: meta, options: .atomic) }
    }

    @discardableResult
    func create(id: String, title: String, audioFile: String, duration: Double,
                language: CallLanguage = .mixed, folderID: String? = nil) -> Recording {
        let r = Recording(id: id, title: title, created: Date(), duration: duration, audioFile: audioFile,
                          results: [], language: language, folderID: folderID)
        recordings.insert(r, at: 0)
        save(r)
        return r
    }

    /// The call language is chosen after recording, so it can change until the first transcription starts.
    func setLanguage(_ id: String, _ language: CallLanguage) {
        guard let i = recordings.firstIndex(where: { $0.id == id }), recordings[i].language != language else { return }
        recordings[i].language = language
        save(recordings[i])
    }

    /// Copies a user-chosen audio file into the library.
    func importAudio(from url: URL, language: CallLanguage = .mixed, folderID: String? = nil) throws -> Recording {
        let id = UUID().uuidString
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let dest = newAudioURL(id: id, ext: ext)
        try FileManager.default.copyItem(at: url, to: dest)
        let duration = (try? AVAudioPlayer(contentsOf: dest))?.duration ?? 0
        return create(id: id, title: url.deletingPathExtension().lastPathComponent,
                      audioFile: dest.lastPathComponent, duration: duration, language: language, folderID: folderID)
    }

    // MARK: Folders

    private var foldersFile: URL { root.appendingPathComponent("folders.json") }

    private func loadFolders() {
        if let data = try? Data(contentsOf: foldersFile), let f = try? decoder.decode([Folder].self, from: data) { folders = f }
    }

    private func saveFolders() {
        if let data = try? encoder.encode(folders) { try? data.write(to: foldersFile, options: .atomic) }
    }

    func folder(_ id: String?) -> Folder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    func children(of parent: String?) -> [Folder] {
        folders.filter { $0.parentID == parent }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func recordings(in folder: String?) -> [Recording] { recordings.filter { $0.folderID == folder } }

    /// "Standups / Team A" for a nested folder, "Library" for the top level.
    func path(of id: String?) -> String {
        var parts: [String] = []
        var current = id
        var steps = 0
        while let c = current, let f = folder(c), steps < 200 {
            parts.insert(f.name, at: 0)
            current = f.parentID
            steps += 1
        }
        return parts.isEmpty ? "Library" : parts.joined(separator: " / ")
    }

    /// The folder itself plus everything nested inside it.
    func descendantIDs(of id: String) -> Set<String> {
        var out: Set<String> = [id]
        var queue = [id]
        while let c = queue.popLast() {
            for f in folders where f.parentID == c && out.insert(f.id).inserted { queue.append(f.id) }
        }
        return out
    }

    func recordingCount(in folderID: String) -> Int {
        let ids = descendantIDs(of: folderID)
        return recordings.filter { r in r.folderID.map(ids.contains) ?? false }.count
    }

    /// Every folder in tree order, with its display path, for "Move to" menus.
    func flatFolders(parent: String? = nil, excluding: Set<String> = []) -> [(folder: Folder, path: String)] {
        children(of: parent).filter { !excluding.contains($0.id) }.flatMap { f in
            [(folder: f, path: path(of: f.id))] + flatFolders(parent: f.id, excluding: excluding)
        }
    }

    @discardableResult
    func createFolder(name: String, color: FolderColor, parent: String?) -> Folder {
        let f = Folder(id: UUID().uuidString, name: name, color: color, parentID: parent, created: Date())
        folders.append(f)
        saveFolders()
        return f
    }

    func updateFolder(_ id: String, name: String, color: FolderColor) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        folders[i].color = color
        saveFolders()
    }

    /// Refuses to move a folder into itself or one of its own subfolders.
    @discardableResult
    func moveFolder(_ id: String, to parent: String?) -> Bool {
        if let p = parent, descendantIDs(of: id).contains(p) { return false }
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].parentID != parent else { return false }
        folders[i].parentID = parent
        saveFolders()
        return true
    }

    /// Deleting a folder never deletes audio: its subfolders and recordings move up one level.
    func deleteFolder(_ id: String) {
        guard let f = folder(id) else { return }
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = f.parentID }
        for r in recordings where r.folderID == id { setFolder(r.id, f.parentID) }
        folders.removeAll { $0.id == id }
        saveFolders()
    }

    func setFolder(_ recordingID: String, _ folderID: String?) {
        mutate(recordingID) { $0.folderID = folderID }
    }

    func rename(_ id: String, to title: String) {
        mutate(id) { $0.title = title }
    }

    func addResult(_ result: TranscriptResult, to id: String) {
        mutate(id) { r in
            r.results.removeAll { $0.provider == result.provider }
            r.results.append(result)
        }
    }

    func setNotes(_ notes: MeetingNotes?, for id: String) {
        mutate(id) { $0.notes = notes }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
        recordings.removeAll { $0.id == id }
    }

    private func mutate(_ id: String, _ change: (inout Recording) -> Void) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[i])
        save(recordings[i])
    }
}

func formatTime(_ t: Double) -> String {
    let s = Int(max(0, t).rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
