import SwiftUI
import AppKit

// MARK: - Find state

@MainActor
final class FindState: ObservableObject {
    @Published var show = false
    @Published var query = ""
    @Published var index = 0
}

// MARK: - Transcript pane

/// The transcript text with its find bar. It only reads values that change rarely, so it is not rebuilt while
/// the audio plays.
struct TranscriptPane: View {
    let text: String
    let fontSize: Double
    let reading: Bool
    @ObservedObject var find: FindState

    var body: some View {
        let doc = TranscriptDoc(text: text, query: find.show ? find.query : "")
        VStack(spacing: 0) {
            if find.show {
                FindBar(query: $find.query, count: doc.matches.count, current: $find.index) { find.show = false }
                Rectangle().fill(G.border).frame(height: 1)
            }
            TranscriptBody(doc: doc, fontSize: CGFloat(fontSize), reading: reading,
                           current: find.show && !doc.matches.isEmpty ? min(find.index, doc.matches.count - 1) : nil)
        }
    }
}

// MARK: - Player

/// Play, pause, stop, seek, export audio. Owns the player so the rest of the screen is not redrawn ten times a second.
struct PlayerBar: View {
    let recording: Recording
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var ui: UIState
    @StateObject private var player = Player()
    @State private var keyMonitor: Any?

    var body: some View {
        let duration = player.duration > 0 ? player.duration : recording.duration
        HStack(spacing: 10) {
            Button { if !player.isPlaying { player.toggle() } } label: { GIcon("play.fill", size: 13) }
                .buttonStyle(.g(player.isPlaying ? .secondary : .primary, square: true))
                .help("Play (Space)").accessibilityLabel("Play")
            Button { if player.isPlaying { player.toggle() } } label: { GIcon("pause.fill", size: 13) }
                .buttonStyle(.g(player.isPlaying ? .primary : .secondary, square: true))
                .help("Pause (Space)").accessibilityLabel("Pause")
            Button { player.stop() } label: { GIcon("stop.fill", size: 13) }
                .buttonStyle(.g(.secondary, square: true))
                .help("Stop").accessibilityLabel("Stop")
            Text(formatTime(player.current)).font(GFont.mono(12)).padding(.leading, 4)
            Scrubber(seed: recording.id, progress: duration > 0 ? player.current / duration : 0) { p in
                player.seek(p * duration)
            }
            Text(formatTime(duration)).font(GFont.mono(12)).foregroundStyle(G.text3)
            Button(action: exportAudio) { IconLabel("Export audio", "square.and.arrow.down") }
                .buttonStyle(.g(.secondary)).padding(.leading, 4)
            Button { NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: recording)]) } label: {
                IconLabel("Show in Finder", "folder")
            }
            .buttonStyle(.g(.secondary))
            .help("Show the saved audio file in Finder")
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .card(padding: 0, radius: 12)
        .onAppear {
            player.load(store.audioURL(for: recording))
            installSpaceKey()
        }
        .onDisappear {
            player.stop()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Space toggles play and pause, unless a text field is being edited or a dialog is open.
    private func installSpaceKey() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        let player = player, ui = ui
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                if ui.modal != nil { return false }
                let responder = NSApp.keyWindow?.firstResponder
                if responder is NSText || responder is NSTextField { return false }
                player.toggle()
                return true
            }
            return handled ? nil : event
        }
    }

    private func exportAudio() {
        let src = store.audioURL(for: recording)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(recording.title).\(src.pathExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.removeItem(at: url)
            do {
                try FileManager.default.copyItem(at: src, to: url)
                ui.toast("Audio exported", icon: "checkmark.circle", actionTitle: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                ui.toast("Could not export the audio: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill")
            }
        }
    }
}

/// Bars in the player: the played part is accent. Drag or click to seek.
/// The bars are a fixed pattern seeded by the recording, not the real waveform.
struct Scrubber: View {
    let seed: String
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let step: CGFloat = 6
                let n = max(1, Int(size.width / step))
                let s = Double(seed.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 97 }) / 10
                for i in 0..<n {
                    let v = abs(sin(Double(i) * 0.5 + 0.7 + s) * cos(Double(i) * 0.21 + 1.4)) * 0.7 + 0.25 * abs(sin(Double(i) * 1.7))
                    let h = max(4, CGFloat(v) * (size.height - 4))
                    let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: 3, height: h)
                    let played = Double(i) / Double(n) < progress
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(played ? G.accent : G.bar))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(min(1, max(0, v.location.x / max(1, geo.size.width))))
            })
        }
        .frame(height: 36)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

// MARK: - Opinions list

/// What each engine does with your data, shown before you pick it.
private func opinionBlurb(_ k: ProviderKind) -> String {
    switch k {
    case .local: return "Stays on this Mac, nothing is sent"
    case .gemini: return "Sends the audio to Google"
    case .elevenlabs: return "Sends the audio to ElevenLabs"
    case .claude: return "Reads the existing transcripts only. Sends the text, never audio, to Anthropic"
    }
}

struct OpinionList: View {
    let recording: Recording
    let onPick: (ProviderKind) -> Void
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Get another opinion").padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ForEach(ProviderKind.allCases) { k in
                let already = recording.results.contains { $0.provider == k }
                let blocked = jobs.isRunning(recording.id, k) || (!k.hearsAudio && recording.results.isEmpty)
                Button { onPick(k) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        GIcon(k.isCloud ? "cloud" : "cpu", size: 13).foregroundStyle(k.isCloud ? G.warnIcon : G.accentText).frame(width: 18).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.title + (already ? " (run again)" : "") + (k.hearsAudio ? "" : " · reads text only"))
                                .font(GFont.ui(13, .semibold))
                            Text(!k.hearsAudio && recording.results.isEmpty ? "Needs at least one transcript first" : opinionBlurb(k))
                                .font(GFont.ui(12)).foregroundStyle(G.text2).fixedSize(horizontal: false, vertical: true)
                            Text(settings.name(k, language: recording.callLanguage)).font(GFont.mono(11)).foregroundStyle(G.text3)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(blocked ? G.text3 : G.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(blocked)
            }
        }
        .padding(.bottom, 6)
        .frame(width: 360)
        .background(G.surface)
    }
}

// MARK: - Recording detail

struct DetailView: View {
    let recording: Recording
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner
    @EnvironmentObject var ui: UIState
    @State private var chosen: ProviderKind?
    @State private var showOpinions = false
    @StateObject private var find = FindState()
    @AppStorage("transcriptFontSize") private var fontSize = 14.0
    @AppStorage("transcriptReading") private var reading = false

    /// Always read the newest copy: results arrive after this view was created.
    private var current: Recording { store.recordings.first { $0.id == recording.id } ?? recording }

    private var runningKinds: [ProviderKind] {
        ProviderKind.allCases.filter { jobs.isRunning(recording.id, $0) }
    }

    private var tabKinds: [ProviderKind] {
        var kinds = current.results.map(\.provider)
        for k in runningKinds where !kinds.contains(k) { kinds.append(k) }
        return kinds
    }

    private var selectedKind: ProviderKind? {
        if let chosen, tabKinds.contains(chosen) { return chosen }
        return tabKinds.first
    }

    private var shown: TranscriptResult? {
        guard let k = selectedKind else { return nil }
        return current.results.first { $0.provider == k }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PlayerBar(recording: recording)
            transcriptCard
        }
        .padding(.top, 20).padding(.horizontal, 28).padding(.bottom, 24)
        .onAppear {
            ui.exportHandler = { exportTranscript() }
            applyPendingFind()
        }
        .onDisappear { ui.exportHandler = nil }
        .onChange(of: ui.pendingFind) { _, _ in applyPendingFind() }
        .onChange(of: ui.findToken) { _, _ in find.show = true }
    }

    private func applyPendingFind() {
        guard let req = ui.pendingFind else { return }
        find.query = req.query
        find.index = 0
        find.show = true
        if let p = req.provider, tabKinds.contains(p) { chosen = p }
        ui.pendingFind = nil
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let f = store.folder(current.folderID) { FolderSwatch(color: f.color.swiftUI) }
                    Text(store.path(of: current.folderID)).font(GFont.ui(12)).foregroundStyle(G.text3)
                }
                HStack(spacing: 10) {
                    Text(current.title.isEmpty ? "Title" : current.title)
                        .font(GFont.ui(22, .semibold)).tracking(-0.4).lineLimit(1)
                        .opacity(0).padding(.trailing, 12)
                        .overlay {
                            TextField("Title", text: Binding(get: { current.title }, set: { store.rename(recording.id, to: $0) }))
                                .textFieldStyle(.plain)
                                .font(GFont.ui(22, .semibold)).tracking(-0.4)
                                .focusEffectDisabled()
                        }
                    Chip(text: recording.callLanguage.title)
                    Spacer(minLength: 0)
                }
            }
            Button { ui.modal = .moveRecording(current) } label: { GIcon("folder", size: 14) }
                .buttonStyle(.g(.secondary, square: true))
                .help("Move to a folder").accessibilityLabel("Move to a folder")
            Button { ui.modal = .deleteRecording(current) } label: { GIcon("trash", size: 14) }
                .buttonStyle(.g(.secondary, square: true))
                .help("Delete recording").accessibilityLabel("Delete recording")
        }
    }

    // MARK: Transcript card

    private var transcriptCard: some View {
        VStack(spacing: 0) {
            tabsRow
            Rectangle().fill(G.border).frame(height: 1)
            errors
            transcriptArea
            Rectangle().fill(G.border).frame(height: 1)
            actionsRow
        }
        .clippedCard()
        .frame(maxHeight: .infinity)
    }

    private var tabsRow: some View {
        HStack(spacing: 0) {
            ForEach(tabKinds) { k in
                let on = selectedKind == k
                let result = current.results.first { $0.provider == k }
                let running = jobs.isRunning(recording.id, k)
                Button { chosen = k } label: {
                    HStack(spacing: 8) {
                        GIcon(k.isCloud ? "cloud" : "cpu", size: 12)
                        Text(result?.tabTitle ?? k.short).lineLimit(1)
                        if running {
                            Text(tabProgress(k)).font(GFont.mono(11)).foregroundStyle(G.accentText)
                        }
                        if jobs.error(recording.id, k) != nil && result == nil {
                            GIcon("exclamationmark.triangle.fill", size: 11).foregroundStyle(G.warnIcon)
                        }
                    }
                    .font(GFont.ui(13, .medium))
                    .foregroundStyle(on ? G.text : G.text2)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .overlay(alignment: .bottom) { Rectangle().fill(on ? G.accent : Color.clear).frame(height: 2) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(result.map { "\($0.modelName), \(Int($0.seconds)) s" } ?? "Running")
            }
            ForEach(ProviderKind.allCases.filter { k in
                jobs.error(recording.id, k) != nil && !tabKinds.contains(k)
            }) { k in
                Button { chosen = nil } label: {
                    HStack(spacing: 8) {
                        GIcon("exclamationmark.triangle.fill", size: 11).foregroundStyle(G.warnIcon)
                        Text(k.short + " failed")
                    }
                    .font(GFont.ui(13, .medium)).foregroundStyle(G.text2).padding(.horizontal, 14).frame(height: 40)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if shown != nil { readingControls }
        }
        .padding(.horizontal, 8)
        .frame(height: 41)
    }

    private var readingControls: some View {
        HStack(spacing: 6) {
            Button { find.show.toggle() } label: { GIcon("magnifyingglass", size: 12) }
                .buttonStyle(.g(find.show ? .secondary : .quiet, height: 28, square: true))
                .help("Find in transcript (⌘F)").accessibilityLabel("Find in transcript")
            Button { fontSize = max(11, fontSize - 1) } label: { Text("A−").font(GFont.ui(12, .semibold)) }
                .buttonStyle(.g(.quiet, height: 28, square: true)).help("Smaller text").accessibilityLabel("Smaller text")
            Button { fontSize = min(24, fontSize + 1) } label: { Text("A+").font(GFont.ui(12, .semibold)) }
                .buttonStyle(.g(.quiet, height: 28, square: true)).help("Larger text").accessibilityLabel("Larger text")
            Button { reading.toggle() } label: { GIcon("book", size: 12) }
                .buttonStyle(.g(reading ? .secondary : .quiet, height: 28, square: true))
                .help(reading ? "Standard view" : "Reading view").accessibilityLabel("Reading view")
        }
    }

    private func tabProgress(_ k: ProviderKind) -> String {
        guard let p = jobs.progress(recording.id, k) else { return "…" }
        if let f = p.fraction ?? p.stageFraction { return "\(Int(f * 100))%" }
        return p.elapsedText
    }

    @ViewBuilder private var errors: some View {
        let failing = ProviderKind.allCases.filter { jobs.error(recording.id, $0) != nil }
        if !failing.isEmpty {
            VStack(spacing: 10) {
                ForEach(failing) { k in
                    JobErrorPanel(kind: k, message: jobs.error(recording.id, k) ?? "", recording: current,
                                  onRetry: { jobs.dismissError(recording.id, k); start(k) },
                                  onDismiss: { jobs.dismissError(recording.id, k) })
                }
            }
            .padding(.vertical, 12)
        }
    }

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let r = shown {
                if r.provider == .claude {
                    HStack(alignment: .top, spacing: 10) {
                        GIcon("sparkles", size: 13).foregroundStyle(G.accentText).padding(.top, 1)
                        Text("Text review by Claude. It read the other transcripts only, not the audio, and returned one reviewed version.")
                            .font(GFont.ui(12)).foregroundStyle(G.text2)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(G.accentSoft.opacity(0.6))
                }
                TranscriptPane(text: r.text, fontSize: fontSize, reading: reading, find: find)
            } else if let k = selectedKind, jobs.isRunning(recording.id, k) {
                TranscribingView(recording: current, provider: k)
            } else if runningKinds.isEmpty {
                if ProviderKind.allCases.contains(where: { jobs.error(recording.id, $0) != nil }) {
                    Color.clear.frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        Text("No transcript yet.").font(GFont.ui(14)).foregroundStyle(G.text2)
                        Text("Call language").font(GFont.ui(12)).foregroundStyle(G.text3)
                        GSegmented(options: CallLanguage.allCases,
                                   selection: Binding(get: { current.callLanguage }, set: { store.setLanguage(recording.id, $0) }),
                                   title: { $0.title }, label: "Call language")
                            .frame(maxWidth: 360)
                        Button("Transcribe with \(settings.name(settings.primary, language: current.callLanguage))") { start(settings.primary) }
                            .buttonStyle(.g(.primary, height: 40))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                TranscribingView(recording: current, provider: runningKinds[0])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button { copy(shown?.text ?? ""); ui.toast("Copied") } label: { IconLabel("Copy transcript", "doc.on.doc") }
                .buttonStyle(.g(.secondary)).disabled(shown == nil)
            Button { copy(settings.template + (shown?.text ?? "")); ui.toast("Copied for Claude", icon: "doc.text") } label: {
                IconLabel("Copy for Claude", "doc.text")
            }
            .buttonStyle(.g(.secondary)).disabled(shown == nil)
            exportMenu
            Spacer()
            Button { showOpinions.toggle() } label: {
                IconLabel("Get another opinion", "sparkles", trailing: "chevron.up")
            }
            .buttonStyle(.g(.opinion))
            .popover(isPresented: $showOpinions, arrowEdge: .top) {
                OpinionList(recording: current) { k in
                    showOpinions = false
                    start(k)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var exportMenu: some View {
        Menu {
            Button { exportTranscript() } label: {
                Label("Transcript as text…", systemImage: "doc.text")
            }
            .disabled(shown == nil)
            Button { exportAudioCopy() } label: { Label("Audio file…", systemImage: "waveform") }
            Divider()
            Button { ui.modal = .export(ids: [recording.id]) } label: {
                Label("Everything…", systemImage: "square.and.arrow.up")
            }
        } label: {
            GMenuLabel(content: AnyView(IconLabel("Export", "square.and.arrow.down", trailing: "chevron.down")))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Export (⌘E exports the transcript)")
    }

    private func start(_ k: ProviderKind) {
        if settings.issue(for: k, language: current.callLanguage) != nil {
            jobs.start(current, kind: k)      // records the "not ready" message as an error row
            return
        }
        chosen = k
        if k.isCloud { ui.modal = .confirmCloud(current, k) } else { jobs.start(current, kind: k) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportTranscript() {
        guard let r = shown else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(current.title) (\(r.tabTitle)).txt"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try r.text.write(to: url, atomically: true, encoding: .utf8)
                ui.toast("Transcript exported", icon: "checkmark.circle", actionTitle: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                ui.toast("Could not export: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func exportAudioCopy() {
        let src = store.audioURL(for: recording)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(current.title).\(src.pathExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.removeItem(at: url)
            do {
                try FileManager.default.copyItem(at: src, to: url)
                ui.toast("Audio exported", icon: "checkmark.circle", actionTitle: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                ui.toast("Could not export the audio: \(error.localizedDescription)", icon: "exclamationmark.triangle.fill")
            }
        }
    }
}
