import SwiftUI
import AppKit

// MARK: - Export everything

/// A thin layer over `Exporter`'s naming and document helpers. For each recording it writes one folder,
/// named by title and date and never colliding with an existing one:
///   the audio file, one text file per transcript ("Title - Gemini.txt"), one combined Markdown file,
///   and a small metadata.json. Speaker labels stay in the text because they are part of the transcript.
enum FullExporter {
    static func uniqueFolder(_ stem: String, in dest: URL, used: inout Set<String>) -> URL {
        let fm = FileManager.default
        var name = stem
        var n = 2
        while used.contains(name.lowercased()) || fm.fileExists(atPath: dest.appendingPathComponent(name).path) {
            name = "\(stem) \(n)"
            n += 1
        }
        used.insert(name.lowercased())
        return dest.appendingPathComponent(name, isDirectory: true)
    }

    static func run(_ sources: [ExportSource], to dest: URL, cancellation: ExportCancellation,
                    progress: @escaping @Sendable (ExportProgress) -> Void) -> ExportResult {
        var result = ExportResult(destination: dest)
        var used = Set<String>()
        let fm = FileManager.default
        for (i, s) in sources.enumerated() {
            if cancellation.isCancelled { result.cancelled = true; break }
            let r = s.recording
            progress(ExportProgress(completed: i, total: sources.count, current: r.title))
            var item = ExportItemResult(recordingID: r.id, title: r.title, files: [], errors: [], warnings: [])
            let stem = Exporter.sanitize(r.title, fallback: "Recording") + " " + Exporter.stamp(r.created)
            let folder = uniqueFolder(stem, in: dest, used: &used)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                item.errors.append("Could not create the folder: \(error.localizedDescription)")
                result.items.append(item)
                continue
            }
            let base = Exporter.sanitize(r.title, fallback: "Recording")
            var metaFiles: [[String: Any]] = []

            // Audio
            if fm.fileExists(atPath: s.audioURL.path) {
                let ext = s.audioURL.pathExtension.isEmpty ? "m4a" : s.audioURL.pathExtension
                let to = folder.appendingPathComponent("\(base).\(ext)")
                do { try fm.copyItem(at: s.audioURL, to: to); item.files.append(to) }
                catch { item.errors.append("Audio: \(error.localizedDescription)") }
            } else {
                item.warnings.append("The audio file is missing, so it was not exported.")
            }

            // One text file per transcript
            let tabs = Exporter.chosenTabs(r, .allTabs).tabs
            var taken = Set<String>()
            for t in tabs {
                var name = "\(base) - \(t.provider.short)"
                var k = 2
                while taken.contains(name.lowercased()) { name = "\(base) - \(t.provider.short) \(k)"; k += 1 }
                taken.insert(name.lowercased())
                let to = folder.appendingPathComponent("\(name).txt")
                do {
                    try (t.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: to, atomically: true, encoding: .utf8)
                    item.files.append(to)
                    metaFiles.append(["file": to.lastPathComponent, "provider": t.provider.rawValue, "model": t.modelName,
                                      "seconds": t.seconds, "date": iso(t.date)])
                } catch { item.errors.append("\(t.provider.short): \(error.localizedDescription)") }
            }
            if tabs.isEmpty { item.warnings.append("No transcript yet; exported the audio and metadata only.") }

            // Combined Markdown
            let combined = Exporter.document(for: r, tabs: tabs, format: .markdown, folderPath: s.folderComponents.joined(separator: " / "))
            let mdURL = folder.appendingPathComponent("\(base).md")
            do { try combined.write(to: mdURL, atomically: true, encoding: .utf8); item.files.append(mdURL) }
            catch { item.errors.append("Markdown: \(error.localizedDescription)") }

            // Metadata
            let meta: [String: Any] = [
                "id": r.id, "title": r.title, "created": iso(r.created), "durationSeconds": r.duration,
                "language": r.callLanguage.rawValue, "folder": s.folderComponents.joined(separator: " / "),
                "audioFile": r.audioFile, "transcripts": metaFiles, "exportedAt": iso(Date()), "app": "Scribe",
            ]
            let jsonURL = folder.appendingPathComponent("metadata.json")
            do {
                let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: jsonURL, options: .atomic)
                item.files.append(jsonURL)
            } catch { item.errors.append("Metadata: \(error.localizedDescription)") }

            result.items.append(item)
        }
        progress(ExportProgress(completed: sources.count, total: sources.count, current: ""))
        return result
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }
}

@MainActor
final class FullExportModel: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: ExportProgress?
    @Published private(set) var result: ExportResult?
    private var token = ExportCancellation()

    func start(ids: [String], store: RecordingStore, to destination: URL) {
        guard !isExporting else { return }
        let sources = Exporter.sources(ids: ids, in: store)
        isExporting = true
        result = nil
        progress = ExportProgress(completed: 0, total: sources.count, current: sources.first?.recording.title ?? "")
        let token = ExportCancellation()
        self.token = token
        let model = self
        Task {
            let res = await Task.detached(priority: .userInitiated) {
                FullExporter.run(sources, to: destination, cancellation: token) { p in
                    Task { @MainActor in model.progress = p }
                }
            }.value
            model.result = res
            model.isExporting = false
        }
    }

    func cancel() { token.cancel() }
}

// MARK: - Dialog

struct ExportDialog: View {
    let ids: [String]
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var ui: UIState
    @StateObject private var model = FullExportModel()

    private var recordings: [Recording] { ids.compactMap { id in store.recordings.first { $0.id == id } } }

    var body: some View {
        ModalScrim(onCancel: { if !model.isExporting { ui.modal = nil } }) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    GIcon("square.and.arrow.up", size: 18).foregroundStyle(G.accentText)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.accentSoft))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recordings.count == 1 ? "Export this recording" : "Export \(recordings.count) recordings")
                            .font(GFont.ui(18, .semibold)).tracking(-0.2)
                        Text("Everything for each recording, in its own folder named by title and date. Nothing is overwritten.")
                            .font(GFont.ui(14)).foregroundStyle(G.text2).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let result = model.result { done(result) }
                else if model.isExporting { running }
                else { ready }
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                include("waveform", "The audio file")
                include("doc.text", "Every transcript as its own text file, one per model")
                include("doc.richtext", "One combined Markdown file")
                include("curlybraces", "A small metadata.json (title, date, length, models)")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { ui.modal = nil }.buttonStyle(.g(.secondary, height: 36))
                Button { chooseFolder() } label: { IconLabel("Choose folder…", "folder") }
                    .buttonStyle(.g(.primary, height: 36)).keyboardShortcut(.defaultAction)
                    .disabled(recordings.isEmpty)
            }
        }
    }

    private func include(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            GIcon(icon, size: 13).foregroundStyle(G.accentText).frame(width: 18)
            Text(text).font(GFont.ui(13))
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            let p = model.progress
            ZStack(alignment: .leading) {
                Capsule().fill(G.surface3)
                GeometryReader { geo in Capsule().fill(G.accent).frame(width: max(6, geo.size.width * (p?.fraction ?? 0))) }
            }
            .frame(height: 6)
            HStack {
                Text("\(p?.completed ?? 0) of \(p?.total ?? 0)").font(GFont.mono(12))
                Text(p?.current ?? "").font(GFont.ui(12)).foregroundStyle(G.text2).lineLimit(1)
                Spacer()
                Button("Stop") { model.cancel() }.buttonStyle(.g(.secondary, height: 30))
            }
        }
    }

    private func done(_ r: ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                GIcon(r.allSucceeded ? "checkmark.circle" : "exclamationmark.triangle.fill", size: 14)
                    .foregroundStyle(r.allSucceeded ? G.success : G.warnIcon)
                Text(r.summary).font(GFont.ui(13, .medium))
            }
            ForEach(r.failedItems) { item in
                Text("\(item.title): \(item.errors.joined(separator: " "))")
                    .font(GFont.ui(12)).foregroundStyle(G.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Show in Finder") { reveal(r) }.buttonStyle(.g(.secondary, height: 36))
                Button("Done") { ui.modal = nil }.buttonStyle(.g(.primary, height: 36)).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { if r.allSucceeded { finishQuietly(r) } }
    }

    private func finishQuietly(_ r: ExportResult) {
        ui.modal = nil
        ui.toast(r.summary, icon: "checkmark.circle", actionTitle: "Show in Finder") { reveal(r) }
    }

    private func reveal(_ r: ExportResult) {
        let first = r.files.first ?? r.destination
        NSWorkspace.shared.activateFileViewerSelecting([first])
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = recordings.count == 1 ? "Choose where to put the export folder" : "Choose where to put the export folders"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.start(ids: ids, store: store, to: url)
    }
}
