import Foundation
import Combine

// Multi-select export. No panels and no UI: the caller picks a destination folder
// (NSOpenPanel / fileExporter) and hands it to `Exporter`.
//
//   ExportOptions   what to write (transcripts, audio, layout, format)
//   Exporter        plan + write, with progress, per-item errors, and never overwrites a file
//   ExportModel     @MainActor ObservableObject wrapper that runs off the main thread

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case text, markdown
    var id: String { rawValue }
    var ext: String { self == .text ? "txt" : "md" }
    var title: String { self == .text ? "Plain text (.txt)" : "Markdown (.md)" }
}

enum ExportLayout: String, CaseIterable, Identifiable, Codable {
    /// Every file in the destination folder.
    case flat
    /// Recreate the library's folder tree under the destination.
    case mirrorFolders
    var id: String { rawValue }
    var title: String { self == .flat ? "One folder" : "Mirror the folder tree" }
}

enum ExportTranscripts: Equatable {
    /// The named provider's tab; if a recording lacks it, the best available tab is used and noted as a warning.
    case preferred(ProviderKind)
    /// One file per tab: "Title - Gemini.md".
    case allTabs
    /// One file per recording with every tab as a section.
    case combined
}

struct ExportOptions: Equatable {
    var transcripts: ExportTranscripts = .preferred(.local)
    var includeAudio = false
    var layout: ExportLayout = .mirrorFolders
    var format: ExportFormat = .markdown
    /// Put every selected recording into a single document instead of one file each.
    /// Audio (if included) still goes alongside as separate files; layout is ignored.
    var singleDocument = false
}

struct ExportProgress: Equatable {
    let completed: Int
    let total: Int
    /// Title of the recording being written (or just finished).
    let current: String
    var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

struct ExportItemResult: Identifiable, Equatable {
    var id: String { recordingID }
    let recordingID: String
    let title: String
    var files: [URL] = []
    /// Problems that stopped something being written.
    var errors: [String] = []
    /// Things worth knowing that did not stop the export (fell back to another tab, no audio asked for...).
    var warnings: [String] = []
    var succeeded: Bool { errors.isEmpty && !files.isEmpty }
}

struct ExportResult: Equatable {
    let destination: URL
    var items: [ExportItemResult] = []
    var cancelled = false
    /// Every file written, each once (a single-document export shares one file across items).
    var files: [URL] {
        var seen = Set<URL>()
        return items.flatMap(\.files).filter { seen.insert($0).inserted }
    }
    var succeededCount: Int { items.filter(\.succeeded).count }
    var failedItems: [ExportItemResult] { items.filter { !$0.errors.isEmpty } }
    var failedCount: Int { failedItems.count }
    var allSucceeded: Bool { !cancelled && failedCount == 0 }
    /// "Exported 5 recordings (12 files)." or "Exported 4 of 5 recordings. 1 failed."
    var summary: String {
        let n = items.count
        let files = self.files.count
        var s = failedCount == 0
            ? "Exported \(succeededCount) recording\(succeededCount == 1 ? "" : "s") (\(files) file\(files == 1 ? "" : "s"))."
            : "Exported \(succeededCount) of \(n) recordings. \(failedCount) failed."
        if cancelled { s += " Cancelled." }
        return s
    }
}

/// Everything the exporter needs about one recording, copied out of the store so it can run off the main actor.
struct ExportSource: Sendable {
    let recording: Recording
    /// Folder names from the top down; empty at the top level.
    let folderComponents: [String]
    let audioURL: URL
}

final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

struct PlannedFile: Equatable {
    enum Kind: Equatable { case transcript, audio }
    let kind: Kind
    let url: URL
}

struct ExportPlanItem: Equatable {
    let recordingID: String
    let title: String
    var files: [PlannedFile]
    var warnings: [String]
    var errors: [String]
}

enum Exporter {
    /// Order tried when the preferred provider is missing from a recording.
    static let fallbackOrder: [ProviderKind] = [.claude, .claudeCode, .gemini, .elevenlabs, .local]

    // MARK: Names

    /// A safe file name stem: no path separators or control characters, no leading dot,
    /// at most 120 UTF-8 bytes, never empty.
    static func sanitize(_ raw: String, fallback: String = "Untitled") -> String {
        let bad: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\u{0}"]
        var out = ""
        for ch in raw.precomposedStringWithCanonicalMapping {
            if bad.contains(ch) { out.append("-") }
            else if ch.isNewline || ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { out.append(" ") }
            else { out.append(ch) }
        }
        out = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        while out.hasPrefix(".") || out.hasPrefix(" ") { out.removeFirst() }
        while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
        // Truncate on a character boundary, by bytes.
        var bytes = 0
        var cut = out.startIndex
        for i in out.indices {
            let next = out.index(after: i)
            let b = out[i..<next].utf8.count
            if bytes + b > 120 { break }
            bytes += b
            cut = next
        }
        out = String(out[..<cut])
        while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
        let reserved: Set<String> = ["con", "prn", "aux", "nul", "com1", "com2", "com3", "lpt1", "lpt2", "lpt3"]
        if out.isEmpty { return fallback }
        if reserved.contains(out.lowercased()) { out += "_" }
        return out
    }

    /// Name to put in a save panel for one recording, e.g. "Standup 16 Nov.md".
    /// Pass `tab` to add the provider ("Standup - Gemini.md"), or `combined` for the all-tabs document.
    static func defaultFileName(for r: Recording, format: ExportFormat = .markdown, tab: ProviderKind? = nil) -> String {
        var stem = sanitize(r.title, fallback: "Recording \(stamp(r.created))")
        if let tab, r.results.count > 1 || r.results.first?.provider != tab { stem += " - \(tab.short)" }
        return "\(stem).\(format.ext)"
    }

    /// "Scribe export 2026-11-16" for a folder, or the recording's own name when there is one.
    static func defaultBatchName(for recordings: [Recording], format: ExportFormat = .markdown) -> String {
        if recordings.count == 1, let r = recordings.first { return defaultFileName(for: r, format: format) }
        return "Scribe export \(stamp(Date(), time: false))"
    }

    static func stamp(_ d: Date, time: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = time ? "yyyy-MM-dd HHmm" : "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func headerDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: Which tabs

    /// Tabs to write for one recording, plus any warnings.
    static func chosenTabs(_ r: Recording, _ t: ExportTranscripts) -> (tabs: [TranscriptResult], warnings: [String]) {
        let order = ProviderKind.allCases
        let sorted = r.results.sorted { (order.firstIndex(of: $0.provider) ?? 0) < (order.firstIndex(of: $1.provider) ?? 0) }
        switch t {
        case .allTabs, .combined:
            return (sorted, [])
        case .preferred(let p):
            if let hit = r.results.first(where: { $0.provider == p }) { return ([hit], []) }
            for f in fallbackOrder {
                if let hit = r.results.first(where: { $0.provider == f }) {
                    return ([hit], ["No \(p.short) transcript; used \(f.short) instead."])
                }
            }
            return (r.results.first.map { [$0] } ?? [], r.results.isEmpty ? [] : ["No \(p.short) transcript; used another tab."])
        }
    }

    // MARK: Rendering

    /// The document text for a recording. Pure, so a save panel flow can write it to a chosen URL.
    static func document(for r: Recording, tabs: [TranscriptResult], format: ExportFormat, folderPath: String? = nil,
                         heading: Bool = true) -> String {
        let md = format == .markdown
        var out = ""
        if heading {
            let model = tabs.count == 1 ? modelLine(tabs[0]) : (tabs.isEmpty ? "none" : tabs.map(modelLine).joined(separator: "; "))
            if md {
                out += "# \(r.title)\n\n"
                out += "- **Date:** \(headerDate(r.created))\n"
                out += "- **Duration:** \(formatTime(r.duration))\n"
                out += "- **Model:** \(model)\n"
                if let folderPath, !folderPath.isEmpty { out += "- **Folder:** \(folderPath)\n" }
                out += "\n---\n\n"
            } else {
                out += "\(r.title)\n"
                out += "Date: \(headerDate(r.created))\n"
                out += "Duration: \(formatTime(r.duration))\n"
                out += "Model: \(model)\n"
                if let folderPath, !folderPath.isEmpty { out += "Folder: \(folderPath)\n" }
                out += "\n" + String(repeating: "-", count: 40) + "\n\n"
            }
        }
        if tabs.count <= 1 {
            out += (tabs.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        } else {
            for (i, t) in tabs.enumerated() {
                let h = "\(t.provider.short) (\(t.modelName))"
                out += md ? "## \(h)\n\n" : "== \(h) ==\n\n"
                out += t.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                if i < tabs.count - 1 { out += "\n" }
            }
        }
        return out
    }

    private static func modelLine(_ t: TranscriptResult) -> String { "\(t.provider.short) · \(t.modelName)" }

    // MARK: Planning

    /// Decides every file name and folder without touching the disk except to ask `exists`.
    /// Names are unique among themselves (case-insensitively) and against what already exists,
    /// so nothing is ever overwritten. A recording's transcript and audio share one base name.
    static func plan(_ sources: [ExportSource], to dest: URL, options: ExportOptions,
                     exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [ExportPlanItem] {
        var taken = Set<String>()
        func key(_ u: URL) -> String { u.path.precomposedStringWithCanonicalMapping.lowercased() }
        func free(_ u: URL) -> Bool { !taken.contains(key(u)) && !exists(u) }

        func dir(for s: ExportSource) -> URL {
            guard options.layout == .mirrorFolders, !options.singleDocument else { return dest }
            return s.folderComponents.reduce(dest) { $0.appendingPathComponent(sanitize($1, fallback: "Folder"), isDirectory: true) }
        }

        var items: [ExportPlanItem] = []

        if options.singleDocument {
            let stem = sanitize(sources.count == 1 ? sources[0].recording.title : "Scribe export \(stamp(Date(), time: false))")
            var n = 1
            func url(_ n: Int) -> URL { dest.appendingPathComponent(n == 1 ? "\(stem).\(options.format.ext)" : "\(stem) \(n).\(options.format.ext)") }
            while !free(url(n)) { n += 1 }
            let docURL = url(n)
            taken.insert(key(docURL))
            for s in sources {
                var item = ExportPlanItem(recordingID: s.recording.id, title: s.recording.title, files: [], warnings: [], errors: [])
                let (tabs, warns) = chosenTabs(s.recording, options.transcripts)
                item.warnings += warns
                if tabs.isEmpty { item.warnings.append("No transcript to export.") } else { item.files.append(PlannedFile(kind: .transcript, url: docURL)) }
                if options.includeAudio { planAudio(s, base: nil, dir: dest, into: &item, taken: &taken, exists: exists) }
                if item.files.isEmpty && item.errors.isEmpty { item.errors.append("Nothing to export: no transcript.") }
                items.append(item)
            }
            return items
        }

        for s in sources {
            let r = s.recording
            let d = dir(for: s)
            let (tabs, warns) = chosenTabs(r, options.transcripts)
            var item = ExportPlanItem(recordingID: r.id, title: r.title, files: [], warnings: warns, errors: [])
            let audioExt = (r.audioFile as NSString).pathExtension
            let wantAudio = options.includeAudio

            if tabs.isEmpty && !wantAudio {
                item.errors.append("No transcript to export.")
                items.append(item)
                continue
            }
            if tabs.isEmpty { item.warnings.append("No transcript; exported audio only.") }

            let stem = sanitize(r.title, fallback: "Recording \(stamp(r.created))")
            // Transcript file names for this recording, as suffixes on the stem.
            let suffixes: [String] = {
                switch options.transcripts {
                case .allTabs where tabs.count > 1: return tabs.map { " - \($0.provider.short)" }
                case .allTabs: return tabs.map { _ in "" }
                default: return tabs.isEmpty ? [] : [""]
                }
            }()

            var n = 1
            func names(_ n: Int) -> [URL] {
                let base = n == 1 ? stem : "\(stem) \(n)"
                var urls = suffixes.map { d.appendingPathComponent("\(base)\($0).\(options.format.ext)") }
                if wantAudio { urls.append(d.appendingPathComponent(audioExt.isEmpty ? base : "\(base).\(audioExt)")) }
                return urls
            }
            while !names(n).allSatisfy(free) { n += 1 }
            let chosen = names(n)
            for u in chosen { taken.insert(key(u)) }
            for (i, _) in suffixes.enumerated() { item.files.append(PlannedFile(kind: .transcript, url: chosen[i])) }
            if wantAudio { item.files.append(PlannedFile(kind: .audio, url: chosen[chosen.count - 1])) }
            items.append(item)
        }
        return items
    }

    private static func planAudio(_ s: ExportSource, base: String?, dir: URL, into item: inout ExportPlanItem,
                                  taken: inout Set<String>, exists: (URL) -> Bool) {
        let ext = (s.recording.audioFile as NSString).pathExtension
        let stem = sanitize(s.recording.title, fallback: "Recording \(stamp(s.recording.created))")
        var n = 1
        func url(_ n: Int) -> URL {
            let b = n == 1 ? stem : "\(stem) \(n)"
            return dir.appendingPathComponent(ext.isEmpty ? b : "\(b).\(ext)")
        }
        func key(_ u: URL) -> String { u.path.precomposedStringWithCanonicalMapping.lowercased() }
        while taken.contains(key(url(n))) || exists(url(n)) { n += 1 }
        taken.insert(key(url(n)))
        item.files.append(PlannedFile(kind: .audio, url: url(n)))
    }

    // MARK: Running

    /// Writes everything. Blocking: call it off the main thread (see `ExportModel`).
    /// `progress` is called on the calling thread after each recording. One bad recording
    /// never stops the others; check `ExportResult.items` for per-item errors.
    static func run(_ sources: [ExportSource], to dest: URL, options: ExportOptions,
                    cancellation: ExportCancellation = ExportCancellation(),
                    progress: ((ExportProgress) -> Void)? = nil) -> ExportResult {
        var result = ExportResult(destination: dest)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            result.items = sources.map {
                ExportItemResult(recordingID: $0.recording.id, title: $0.recording.title,
                                 errors: ["Cannot create the destination folder: \(error.localizedDescription)"])
            }
            return result
        }

        let plan = plan(sources, to: dest, options: options)
        let total = sources.count
        var singleDoc: String = ""

        for (i, (s, p)) in zip(sources, plan).enumerated() {
            if cancellation.isCancelled { result.cancelled = true; break }
            var item = ExportItemResult(recordingID: p.recordingID, title: p.title, files: [], errors: p.errors, warnings: p.warnings)
            progress?(ExportProgress(completed: i, total: total, current: p.title))

            let (tabs, _) = chosenTabs(s.recording, options.transcripts)
            let folderPath = s.folderComponents.joined(separator: " / ")

            for f in p.files {
                do {
                    switch f.kind {
                    case .transcript:
                        if options.singleDocument {
                            let part = document(for: s.recording, tabs: tabs, format: options.format, folderPath: folderPath)
                            singleDoc += (singleDoc.isEmpty ? "" : (options.format == .markdown ? "\n\n---\n\n" : "\n\n" + String(repeating: "=", count: 40) + "\n\n")) + part
                            if !item.files.contains(f.url) { item.files.append(f.url) }
                        } else if options.transcripts == .allTabs {
                            // One file per tab, in the same order the plan named them.
                            let idx = p.files.filter { $0.kind == .transcript }.firstIndex(of: f) ?? 0
                            let tab = tabs[min(idx, tabs.count - 1)]
                            try write(document(for: s.recording, tabs: [tab], format: options.format, folderPath: folderPath), to: f.url)
                            item.files.append(f.url)
                        } else {
                            try write(document(for: s.recording, tabs: tabs, format: options.format, folderPath: folderPath), to: f.url)
                            item.files.append(f.url)
                        }
                    case .audio:
                        try fm.createDirectory(at: f.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        guard fm.fileExists(atPath: s.audioURL.path) else {
                            item.errors.append("Audio file is missing.")
                            continue
                        }
                        try fm.copyItem(at: s.audioURL, to: f.url)
                        item.files.append(f.url)
                    }
                } catch {
                    item.errors.append("\(f.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            result.items.append(item)
            progress?(ExportProgress(completed: i + 1, total: total, current: p.title))
        }

        if options.singleDocument, let docURL = plan.first?.files.first(where: { $0.kind == .transcript })?.url, !singleDoc.isEmpty {
            do { try write(singleDoc, to: docURL) } catch {
                for i in result.items.indices where result.items[i].files.contains(docURL) {
                    result.items[i].files.removeAll { $0 == docURL }
                    result.items[i].errors.append("\(docURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return result
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// Snapshots recordings and folder paths from the store (main actor) in the order given.
    @MainActor
    static func sources(ids: [String], in store: RecordingStore) -> [ExportSource] {
        let byID = Dictionary(store.recordings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { id in
            guard let r = byID[id] else { return nil }
            var comps: [String] = []
            var cur = r.folderID
            var steps = 0
            while let c = cur, let f = store.folder(c), steps < 200 {
                comps.insert(f.name, at: 0)
                cur = f.parentID
                steps += 1
            }
            return ExportSource(recording: r, folderComponents: comps, audioURL: store.audioURL(for: r))
        }
    }
}

private extension Array where Element == URL {
    func contains(_ u: URL) -> Bool { contains { $0 == u } }
}

/// Runs an export off the main thread and publishes progress for a sheet or toast.
@MainActor
final class ExportModel: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: ExportProgress?
    @Published private(set) var result: ExportResult?

    private var cancellation = ExportCancellation()

    /// Selection order is preserved. Ids that no longer exist are skipped.
    func start(ids: [String], from store: RecordingStore, to destination: URL, options: ExportOptions) {
        guard !isExporting else { return }
        let sources = Exporter.sources(ids: ids, in: store)
        isExporting = true
        result = nil
        progress = ExportProgress(completed: 0, total: sources.count, current: "")
        let token = ExportCancellation()
        cancellation = token
        Task { [weak self] in
            let res = await Task.detached(priority: .userInitiated) {
                Exporter.run(sources, to: destination, options: options, cancellation: token) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
            }.value
            guard let self else { return }
            self.result = res
            self.isExporting = false
            self.progress = ExportProgress(completed: sources.count, total: sources.count, current: "")
        }
    }

    func cancel() { cancellation.cancel() }
    func dismissResult() { result = nil }
}
