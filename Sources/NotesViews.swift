import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Notes pane (the Notes tab of a recording)

struct NotesPane: View {
    let recording: Recording
    @EnvironmentObject var notes: NotesRunner
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState
    @State private var composing = false

    var body: some View {
        VStack(spacing: 0) {
            if let job = notes.job(recording.id) {
                writing(job)
            } else {
                if let e = notes.error(recording.id) { errorBanner(e) }
                if let n = recording.notes, !composing {
                    saved(n)
                } else {
                    NotesComposer(recording: recording, onCancel: recording.notes == nil ? nil : { composing = false }) {
                        composing = false
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // While the model writes: phase, elapsed, the text so far, and Cancel.
    private func writing(_ job: NotesRunner.Job) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(job.phase).font(GFont.ui(13, .semibold))
                Text("\(job.engine.title), \(job.model)").font(GFont.ui(12)).foregroundStyle(G.text3)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(formatTime(ctx.date.timeIntervalSince(job.started))).font(GFont.mono(12)).foregroundStyle(G.text2)
                }
                Button("Cancel") { notes.cancel(recording.id) }.buttonStyle(.g(.secondary, height: 30))
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Rectangle().fill(G.border).frame(height: 1)
            ScrollView {
                MarkdownNotes(text: job.text.isEmpty ? "_Waiting for the first words…_" : job.text)
                    .padding(.horizontal, 28).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private func saved(_ n: MeetingNotes) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GIcon(n.engine.isCloud ? "cloud" : "cpu", size: 12).foregroundStyle(G.text3)
                Text("\(n.engine.title), \(n.model). From the \(n.source.short) transcript, \(n.date.formatted(date: .abbreviated, time: .shortened)).")
                    .font(GFont.ui(12)).foregroundStyle(G.text3).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 10)
            Rectangle().fill(G.border).frame(height: 1)
            ScrollView {
                MarkdownNotes(text: n.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 28).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(G.border).frame(height: 1)
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(n.text, forType: .string)
                    ui.toast("Notes copied")
                } label: { IconLabel("Copy notes", "doc.on.doc") }
                .buttonStyle(.g(.secondary))
                Button { export(n) } label: { IconLabel("Export notes…", "square.and.arrow.down") }
                    .buttonStyle(.g(.secondary))
                Spacer()
                Button { notes.dismissError(recording.id); composing = true } label: { IconLabel("Write again", "arrow.clockwise") }
                    .buttonStyle(.g(.secondary))
                    .help("Write new notes with another model or engine. They replace these.")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private func errorBanner(_ e: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            GIcon("exclamationmark.triangle.fill", size: 13).foregroundStyle(G.warnIcon).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notes could not be written").font(GFont.ui(13, .semibold))
                Text(e).font(GFont.ui(12)).foregroundStyle(G.text2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Dismiss") { notes.dismissError(recording.id) }.buttonStyle(.g(.quiet, height: 28))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.warnBorder))
        .padding(.horizontal, 20).padding(.top, 14)
    }

    private func export(_ n: MeetingNotes) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Exporter.sanitize(recording.title) + " - Notes.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ("# \(recording.title) - Notes\n\n" + n.text + "\n").write(to: url, atomically: true, encoding: .utf8)
            ui.toast("Notes exported", icon: "checkmark.circle", actionTitle: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            ui.toast("Could not export the notes: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill")
        }
    }
}

// MARK: - Composer: engine, model, transcript, then Write

struct NotesComposer: View {
    let recording: Recording
    var onCancel: (() -> Void)?
    let onStart: () -> Void
    @EnvironmentObject var notes: NotesRunner
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState
    @State private var source: ProviderKind?
    @State private var ollamaModels: [OllamaModel] = []
    @State private var ollamaIssue: String?
    @State private var loadingOllama = false

    private var transcript: TranscriptResult? {
        if let source, let t = recording.results.first(where: { $0.provider == source }) { return t }
        return bestTranscript(recording)
    }
    private var model: String { settings.notesEngine == .ollama ? settings.ollamaModel : settings.notesClaudeModel }
    private var blocker: String? {
        if transcript == nil { return "Transcribe this recording first. Notes are written from a transcript." }
        switch settings.notesEngine {
        case .ollama:
            if let ollamaIssue { return ollamaIssue }
            if loadingOllama { return nil }
            if ollamaModels.isEmpty { return "No Ollama models are installed. Install one in Terminal, for example: ollama pull qwen3:8b" }
            if settings.ollamaModel.isEmpty { return "Choose a model." }
        case .claude:
            if ClaudeCodeNotes.findBinary() == nil { return ClaudeCodeNotes.notFound }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Write meeting notes").font(GFont.ui(18, .semibold)).tracking(-0.2)
                    Text("Summary, decisions, action items with owners, and open questions, written from the transcript. Change the format in Settings, Meeting notes.")
                        .font(GFont.ui(13)).foregroundStyle(G.text2).fixedSize(horizontal: false, vertical: true)
                }
                FieldRow(title: "Written by") {
                    GSegmented(options: NotesEngineKind.allCases,
                               selection: Binding(get: { settings.notesEngine }, set: { settings.notesEngine = $0 }),
                               title: { $0.title }, icon: { $0.isCloud ? "cloud" : "cpu" }, label: "Notes engine")
                        .frame(maxWidth: 360)
                }
                FieldRow(title: "Model") { modelPicker }
                if recording.results.count > 1 {
                    FieldRow(title: "From transcript") {
                        GSegmented(options: recording.results.map(\.provider),
                                   selection: Binding(get: { transcript?.provider ?? .local }, set: { source = $0 }),
                                   title: { $0.short }, label: "Transcript to use")
                            .frame(maxWidth: 480)
                    }
                }
                privacyLine
                if let blocker {
                    Text(blocker).font(GFont.ui(12, .semibold)).foregroundStyle(G.warnIcon).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button(settings.notesEngine == .claude ? "Send to Claude and write notes" : "Write notes") { start() }
                        .buttonStyle(.g(.primary, height: 40))
                        .disabled(blocker != nil || loadingOllama)
                    if let onCancel { Button("Cancel", action: onCancel).buttonStyle(.g(.secondary, height: 40)) }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task(id: settings.notesEngine) { if settings.notesEngine == .ollama { await loadOllama() } }
    }

    @ViewBuilder private var modelPicker: some View {
        switch settings.notesEngine {
        case .ollama:
            HStack(spacing: 10) {
                Picker("", selection: $settings.ollamaModel) {
                    if settings.ollamaModel.isEmpty { Text("Choose a model").tag("") }
                    ForEach(ollamaModels) { m in Text("\(m.name)  (\(m.sizeText))").tag(m.name) }
                    if !settings.ollamaModel.isEmpty && !ollamaModels.contains(where: { $0.name == settings.ollamaModel }) {
                        Text(settings.ollamaModel + " (not installed)").tag(settings.ollamaModel)
                    }
                }
                .labelsHidden().frame(maxWidth: 360)
                Button { Task { await loadOllama() } } label: { GIcon("arrow.clockwise", size: 12) }
                    .buttonStyle(.g(.secondary, height: 30, square: true)).help("Check Ollama again")
                if loadingOllama { ProgressView().controlSize(.small) }
            }
        case .claude:
            Picker("", selection: $settings.notesClaudeModel) {
                ForEach(NotesEngineKind.claudeCodeModels, id: \.id) { m in Text(m.name).tag(m.id) }
                if !NotesEngineKind.claudeCodeModels.contains(where: { $0.id == settings.notesClaudeModel }) {
                    Text(settings.notesClaudeModel).tag(settings.notesClaudeModel)
                }
            }
            .labelsHidden().frame(maxWidth: 360)
        }
    }

    @ViewBuilder private var privacyLine: some View {
        let chars = transcript?.text.count ?? 0
        HStack(alignment: .top, spacing: 8) {
            GIcon(settings.notesEngine.isCloud ? "cloud" : "lock.shield", size: 12).padding(.top, 1)
            Text(settings.notesEngine.isCloud
                 ? "The transcript text (\(chars.formatted()) characters) is sent to Anthropic through Claude Code, on your Claude subscription. Audio is not sent."
                 : "Runs on this Mac through Ollama. Nothing leaves it.")
        }
        .font(GFont.ui(12, .semibold))
        .foregroundStyle(settings.notesEngine.isCloud ? G.warnText : G.text2)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(settings.notesEngine.isCloud ? G.warnBg : G.surface2))
    }

    private func loadOllama() async {
        loadingOllama = true
        defer { loadingOllama = false }
        do {
            ollamaModels = try await OllamaClient(settings.ollamaURL).models()
            ollamaIssue = nil
            if settings.ollamaModel.isEmpty, let first = ollamaModels.first { settings.ollamaModel = first.name }
        } catch {
            ollamaModels = []
            ollamaIssue = error.localizedDescription
        }
    }

    private func start() {
        guard let t = transcript else { return }
        notes.start(recording, transcript: t, engine: settings.notesEngine, model: model)
        onStart()
    }
}

// MARK: - Markdown

/// Renders the notes' Markdown: headings, bullets, numbered items and paragraphs, with inline bold,
/// italics and code. SwiftUI's own Markdown support is inline only.
struct MarkdownNotes: View {
    let text: String

    private enum Block: Hashable {
        case heading(String, level: Int), bullet(String, indent: Int), numbered(String, String), paragraph(String), gap
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if out.last != .gap { out.append(.gap) }; continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                out.append(.bullet(String(line.dropFirst(2)), indent: indent))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                out.append(.numbered(String(line[..<dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    private func inline(_ s: String) -> Text {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        return Text(a)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let t, let level):
                    inline(t).font(GFont.ui(level <= 1 ? 18 : (level == 2 ? 16 : 14), .semibold))
                        .padding(.top, 8)
                case .bullet(let t, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(G.text3)
                        inline(t).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .numbered(let n, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(n + ".").font(GFont.mono(12)).foregroundStyle(G.text3)
                        inline(t).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let t):
                    inline(t).fixedSize(horizontal: false, vertical: true)
                case .gap:
                    Spacer().frame(height: 4)
                }
            }
        }
        .font(GFont.ui(14))
        .foregroundStyle(G.text)
        .lineSpacing(3)
    }
}

// MARK: - Settings page

struct NotesSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Meeting notes").font(GFont.ui(20, .semibold)).tracking(-0.4)
                Text("Write notes from a transcript with a local Ollama model, which never leaves this Mac, or with Claude through Claude Code, which reads the transcript text at Anthropic on your Claude subscription.")
                    .font(GFont.ui(14)).foregroundStyle(G.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
            FieldRow(title: "Default engine") {
                GSegmented(options: NotesEngineKind.allCases,
                           selection: Binding(get: { settings.notesEngine }, set: { settings.notesEngine = $0 }),
                           title: { $0.title }, icon: { $0.isCloud ? "cloud" : "cpu" }, label: "Default notes engine")
                    .frame(maxWidth: 360)
            }
            .card(padding: 20)
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Ollama")
                FieldRow(title: "Address") {
                    TextField(AppSettings.defaultOllamaURL, text: $settings.ollamaURL)
                        .textFieldStyle(.roundedBorder).font(GFont.mono(13)).frame(maxWidth: 360)
                }
                HStack(spacing: 10) {
                    Button { Task { await check() } } label: { IconLabel("Check Ollama", "checkmark.circle") }
                        .buttonStyle(.g(.secondary, height: 32))
                    if checking { ProgressView().controlSize(.small) }
                    if let status { Text(status).font(GFont.ui(12)).foregroundStyle(G.text2).textSelection(.enabled) }
                }
                Text("Install Ollama from ollama.com, then a model in Terminal, for example: ollama pull qwen3:8b. With 16 GB of memory, models up to about 12B fit beside Scribe.")
                    .font(GFont.ui(12)).foregroundStyle(G.text3).fixedSize(horizontal: false, vertical: true)
            }
            .card(padding: 20)
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Claude Code")
                FieldRow(title: "Model for notes") {
                    Picker("", selection: $settings.notesClaudeModel) {
                        ForEach(NotesEngineKind.claudeCodeModels, id: \.id) { m in Text(m.name).tag(m.id) }
                        if !NotesEngineKind.claudeCodeModels.contains(where: { $0.id == settings.notesClaudeModel }) {
                            Text(settings.notesClaudeModel).tag(settings.notesClaudeModel)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 360)
                }
                Text(ClaudeCodeNotes.findBinary().map { "Runs \($0) with your Claude Code sign-in, so it uses your Claude subscription, not an API key. Claude gets no tools and no files. Only the transcript text is sent, never audio, and Scribe asks every time." } ?? ClaudeCodeNotes.notFound)
                    .font(GFont.ui(12)).foregroundStyle(G.text3)
            }
            .card(padding: 20)
            FieldRow(title: "Instructions sent with every transcript") {
                TextEditor(text: $settings.notesTemplate)
                    .font(GFont.mono(12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 260)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.borderStrong))
                Button("Reset to default") { settings.notesTemplate = AppSettings.defaultNotesTemplate }
                    .buttonStyle(.g(.quiet, height: 30))
                    .disabled(settings.notesTemplate == AppSettings.defaultNotesTemplate)
            }
            .card(padding: 20)
        }
        .task { await check() }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            let models = try await OllamaClient(settings.ollamaURL).models()
            status = models.isEmpty ? "Running, but no models are installed."
                : "Running. \(models.count) model\(models.count == 1 ? "" : "s"): " + models.map(\.name).joined(separator: ", ")
        } catch {
            status = error.localizedDescription
        }
    }
}
