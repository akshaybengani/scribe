import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner
    @State private var selection: String?
    @State private var folder: String?
    @State private var showSettings = false

    /// Shown on top of the whole app whenever a cloud model is chosen or a cloud job is running.
    private var warning: String? {
        var kinds = jobs.runningCloudKinds
        if settings.primary.isCloud { kinds.insert(settings.primary) }
        guard !kinds.isEmpty else { return nil }
        let parts = ProviderKind.allCases.filter { kinds.contains($0) }.map { k -> String in
            k.hearsAudio
                ? "audio will be sent to \(k.company), a third-party platform, for processing"
                : "transcript text (not audio) will be sent to \(k.company), a third-party platform, for processing"
        }
        return "Cloud model in use: " + parts.joined(separator: "; ") + "."
    }

    var body: some View {
        VStack(spacing: 0) {
            if let warning { WarningBanner(text: warning) }
            NavigationSplitView {
                LibrarySidebar(selection: $selection, folder: $folder)
                    .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
            } detail: {
                if let id = selection, let rec = store.recordings.first(where: { $0.id == id }) {
                    DetailView(recording: rec, showSettings: $showSettings).id(rec.id)
                } else {
                    HomeView(selection: $selection, folder: $folder, showSettings: $showSettings)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showSettings = true } label: { Label("AI Models", systemImage: "gearshape") }
                    .help("AI models and API keys")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings)
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

struct WarningBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.callout.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .foregroundStyle(.black)
        .background(Color.orange)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Home: choose a model, record or import

struct ModelPicker: View {
    @EnvironmentObject var settings: AppSettings
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Transcribe with").foregroundStyle(.secondary)
            Picker("", selection: $settings.primary) {
                ForEach(ProviderKind.allCases.filter(\.hearsAudio)) { k in
                    Text((k.isCloud ? "☁ " : "") + settings.name(k)).tag(k)
                }
            }
            .labelsHidden()
            .frame(width: 280)
            if let issue = settings.issue(for: settings.primary) {
                Button { showSettings = true } label: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help(issue)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Model is ready")
            }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner
    @StateObject private var recorder = Recorder()
    @Binding var selection: String?
    @Binding var folder: String?
    @Binding var showSettings: Bool
    @State private var pending: (id: String, url: URL)?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(store.folder(folder)?.color.swiftUI ?? .secondary)
                Text("Saving into \(store.path(of: folder))").font(.callout).foregroundStyle(.secondary)
            }
            ModelPicker(showSettings: $showSettings)
            Picker("Call language", selection: $settings.callLanguage) {
                ForEach(CallLanguage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .disabled(recorder.isRecording)
            .help("English only uses English-specific models. Hindi + English uses the code-switching model.")
            Toggle("Also record computer audio (Teams, Meet and browser calls)", isOn: $settings.captureSystemAudio)
                .toggleStyle(.checkbox)
                .disabled(recorder.isRecording)
                .help("Captures everything this Mac plays. Use headphones so the microphone does not pick up the speakers a second time.")
            VStack(spacing: 10) {
                LaneView(title: "Microphone", levels: recorder.micLevels, active: recorder.isRecording && !recorder.isPaused, tint: .red)
                if recorder.hasSystemAudio || (!recorder.isRecording && settings.captureSystemAudio) {
                    LaneView(title: "Computer audio", levels: recorder.systemLevels, active: recorder.isRecording && !recorder.isPaused, tint: .blue)
                }
            }
            .padding(.horizontal, 30)
            Text(formatTime(recorder.elapsed))
                .font(.system(size: 34, weight: .light).monospacedDigit())
            HStack(spacing: 30) {
                if recorder.isRecording {
                    Button { recorder.togglePause() } label: {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill").font(.title2).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered).clipShape(Circle())
                    .help(recorder.isPaused ? "Resume" : "Pause")
                }
                Button(action: toggleRecording) {
                    ZStack {
                        Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 3).frame(width: 72, height: 72)
                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 5).fill(Color.red).frame(width: 26, height: 26)
                        } else {
                            Circle().fill(Color.red).frame(width: 58, height: 58)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(recorder.isRecording ? "Stop and transcribe" : "Start recording")
            }
            Button("Import audio file…", action: importAudio).disabled(recorder.isRecording)
            if recorder.micDenied {
                Text("Microphone access is off. Allow Scribe in System Settings > Privacy & Security > Microphone.")
                    .foregroundStyle(.red).font(.callout)
            }
            if recorder.screenDenied {
                Text("Computer audio needs Screen & System Audio Recording access. Allow Scribe in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen Scribe.")
                    .foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }
            if let message = recorder.errorMessage {
                Text(message).foregroundStyle(.orange).font(.callout).multilineTextAlignment(.center)
            }
            if let notice { Text(notice).foregroundStyle(.red).font(.callout) }
            Spacer()
            Text(settings.primary.isCloud
                 ? "The selected model is in the cloud. Choose a Local model to keep audio on this Mac."
                 : "Local model selected. Audio stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleRecording() {
        notice = nil
        if recorder.isRecording {
            Task {
                let duration = await recorder.stop()
                guard let p = pending else { return }
                pending = nil
                let title = "Recording " + Date().formatted(date: .abbreviated, time: .shortened)
                let rec = store.create(id: p.id, title: title, audioFile: p.url.lastPathComponent, duration: duration,
                                       language: settings.callLanguage, folderID: folder)
                selection = rec.id
                jobs.start(rec, kind: settings.primary)
            }
        } else {
            let id = UUID().uuidString
            let url = store.newAudioURL(id: id, ext: "m4a")
            pending = (id, url)
            Task {
                if await recorder.start(to: url, withSystemAudio: settings.captureSystemAudio) == false {
                    pending = nil
                    store.delete(id)
                    if !recorder.micDenied && !recorder.screenDenied && recorder.errorMessage == nil { notice = "Could not start recording." }
                }
            }
        }
    }

    private func importAudio() {
        notice = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to transcribe"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rec = try store.importAudio(from: url, language: settings.callLanguage, folderID: folder)
            selection = rec.id
            jobs.start(rec, kind: settings.primary)
        } catch {
            notice = "Could not import that file: \(error.localizedDescription)"
        }
    }
}

/// One waveform lane with a small label, like a track in Voice Memos.
struct LaneView: View {
    let title: String
    let levels: [Float]
    let active: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            WaveformView(levels: levels, active: active, tint: tint).frame(height: 64)
        }
    }
}

// MARK: - Detail: play, read, export, ask for more opinions

struct DetailView: View {
    let recording: Recording
    @Binding var showSettings: Bool
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner
    @StateObject private var player = Player()
    @State private var chosen: ProviderKind?
    @State private var confirm: ProviderKind?

    private var shown: TranscriptResult? {
        recording.results.first { $0.provider == chosen } ?? recording.results.first
    }

    private var runningKinds: [ProviderKind] {
        ProviderKind.allCases.filter { jobs.isRunning(recording.id, $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("Title", text: Binding(get: { recording.title }, set: { store.rename(recording.id, to: $0) }))
                    .textFieldStyle(.plain).font(.title2.bold())
                Text(recording.callLanguage.title)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            playerBar
            tabsRow
            transcriptArea
            actionsRow
        }
        .padding(20)
        .onAppear { player.load(store.audioURL(for: recording)) }
        .onDisappear { player.stop() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if let k = confirm {
                Button("Send to \(k.company)") { jobs.start(recording, kind: k); confirm = nil }
                Button("Cancel", role: .cancel) { confirm = nil }
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String { confirm.map { "Send to \($0.company)?" } ?? "" }
    private var confirmMessage: String {
        guard let k = confirm else { return "" }
        return k.hearsAudio
            ? "This audio will be uploaded to \(k.company), a third-party platform, for processing."
            : "The existing transcripts (text only, no audio) will be sent to \(k.company), a third-party platform."
    }

    // MARK: Player

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 22) }
                .help(player.isPlaying ? "Pause" : "Play")
            Button { player.stop() } label: { Image(systemName: "stop.fill").frame(width: 22) }.help("Stop")
            Text(formatTime(player.current)).monospacedDigit().foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.current }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
            Text(formatTime(player.duration)).monospacedDigit().foregroundStyle(.secondary)
            Button("Export audio…", action: exportAudio)
            Button { NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: recording)]) } label: {
                Image(systemName: "folder")
            }
            .help("Show the saved audio file in Finder")
        }
    }

    // MARK: Transcript tabs

    private var tabsRow: some View {
        HStack(spacing: 8) {
            ForEach(recording.results) { r in
                Button { chosen = r.provider } label: {
                    HStack(spacing: 4) {
                        if r.provider.isCloud { Image(systemName: "cloud") }
                        Text(r.tabTitle)
                    }
                }
                .buttonStyle(.bordered)
                .tint(shown?.provider == r.provider ? .accentColor : .gray)
                .help("\(r.modelName), \(Int(r.seconds)) s")
            }
            ForEach(runningKinds) { k in
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(k.short + "…") }
                    .padding(.horizontal, 8)
            }
            Spacer()
        }
    }

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ProviderKind.allCases.filter { jobs.error(recording.id, $0) != nil }) { k in
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(k.short): \(jobs.error(recording.id, k) ?? "")").font(.callout).textSelection(.enabled)
                    Spacer()
                    if settings.issue(for: k, language: recording.callLanguage) != nil { Button("AI Models") { showSettings = true } }
                    Button("Dismiss") { jobs.dismissError(recording.id, k) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            if let r = shown {
                ScrollView {
                    Text(r.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            } else if runningKinds.isEmpty {
                VStack(spacing: 10) {
                    Text("No transcript yet.").foregroundStyle(.secondary)
                    Button("Transcribe with \(settings.name(settings.primary, language: recording.callLanguage))") { start(settings.primary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Transcribing… this can take a while for long recordings.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button("Copy transcript") { copy(shown?.text ?? "") }.disabled(shown == nil)
            Button("Copy for Claude") { copy(settings.template + (shown?.text ?? "")) }.disabled(shown == nil)
            Button("Export transcript…", action: exportTranscript).disabled(shown == nil)
            Spacer()
            Menu("Get another opinion") {
                ForEach(ProviderKind.allCases) { k in
                    let already = recording.results.contains { $0.provider == k }
                    Button {
                        start(k)
                    } label: {
                        Text((k.isCloud ? "☁ " : "") + k.title + (already ? " (run again)" : "") + (k.hearsAudio ? "" : " · reads text only"))
                    }
                    .disabled(jobs.isRunning(recording.id, k) || (!k.hearsAudio && recording.results.isEmpty))
                }
            }
            .menuStyle(.borderedButton)
            .fixedSize()
        }
    }

    private func start(_ k: ProviderKind) {
        if settings.issue(for: k, language: recording.callLanguage) != nil {
            jobs.start(recording, kind: k)      // records the "not ready" message as an error row
            return
        }
        if k.isCloud { confirm = k } else { jobs.start(recording, kind: k) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportTranscript() {
        guard let r = shown else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(recording.title) (\(r.tabTitle)).txt"
        if panel.runModal() == .OK, let url = panel.url { try? r.text.write(to: url, atomically: true, encoding: .utf8) }
    }

    private func exportAudio() {
        let src = store.audioURL(for: recording)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(recording.title).\(src.pathExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: src, to: url)
        }
    }
}
