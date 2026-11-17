import SwiftUI
import AppKit
import AVFoundation
import Network
import UniformTypeIdentifiers

// MARK: - App-wide UI state

enum AppSection { case record, library, importAudio, settings, setup }

enum SettingsPage: Hashable {
    case models, local, cloud(ProviderKind), output, storage
}

enum AppModal: Identifiable {
    case newFolder(parent: String?)
    case editFolder(Folder)
    case deleteFolder(Folder)
    case deleteRecording(Recording)
    case confirmCloud(Recording, ProviderKind)
    case export(ids: [String])
    case moveRecording(Recording)
    case deleteAll
    case shortcuts
    case about

    var id: String {
        switch self {
        case .newFolder(let p): return "new-" + (p ?? "root")
        case .editFolder(let f): return "edit-" + f.id
        case .deleteFolder(let f): return "delete-folder-" + f.id
        case .deleteRecording(let r): return "delete-rec-" + r.id
        case .confirmCloud(let r, let k): return "cloud-\(r.id)-\(k.rawValue)"
        case .export(let ids): return "export-" + ids.joined(separator: ",")
        case .moveRecording(let r): return "move-" + r.id
        case .deleteAll: return "delete-all"
        case .shortcuts: return "shortcuts"
        case .about: return "about"
        }
    }
}

struct PendingRecording {
    let id: String
    let url: URL
}

/// What the "Recording saved" screen shows after Stop.
struct SavedRecording: Equatable {
    let id: String
    let provider: ProviderKind
    let sources: String
}

/// Everything that is about the window rather than the data: which screen, which folder, which dialog.
@MainActor
final class UIState: ObservableObject {
    @Published var section: AppSection = .record
    @Published var selection: String?          // recording shown in the detail screen
    @Published var folder: String?             // current folder; new recordings and imports go here
    @Published var collapsed: Set<String> = [] // folders collapsed in the sidebar tree
    @Published var modal: AppModal?
    @Published var toasts: [ToastItem] = []
    @Published var settingsPage: SettingsPage = .models
    /// A recording in progress keeps its file here so it survives switching screens.
    @Published var pending: PendingRecording?
    /// Set when Stop has saved a recording; the Record screen then shows its saved-and-transcribing state.
    @Published var justSaved: SavedRecording?

    /// Bumped by Cmd+K and the sidebar Search entry; the global search field focuses itself when it changes.
    @Published var searchFocusToken = 0
    /// Set when a search result opens a recording: the detail screen opens its find bar on this query.
    @Published var pendingFind: FindRequest?
    /// Bumped by Cmd+F; the detail screen opens or focuses its find bar.
    @Published var findToken = 0
    /// True while the search field has focus; the results panel shows exactly then.
    @Published var searchOpen = false

    /// Library multi-select.
    @Published var selectionMode = false
    @Published var selectedIDs: Set<String> = []

    private var previous: AppSection = .record
    /// Registered by the recording detail screen so Cmd+E can export the transcript on screen.
    var exportHandler: (() -> Void)?

    func focusSearch() { searchFocusToken += 1 }

    func goRecord() { selection = nil; justSaved = nil; section = .record }

    func goLibrary(folder: String?) {
        self.folder = folder
        selection = nil
        section = .library
    }

    func open(recording id: String, folder: String?) {
        self.folder = folder
        selection = id
        section = .library
    }

    func openSettings(_ page: SettingsPage = .models) {
        if section != .settings { previous = section }
        settingsPage = page
        section = .settings
    }

    func closeSettings() {
        section = previous == .settings ? .record : previous
    }

    func endSelection() {
        selectionMode = false
        selectedIDs = []
    }

    func toast(_ text: String, icon: String? = "checkmark.circle", swatch: Color? = nil,
               actionTitle: String? = nil, action: (() -> Void)? = nil) {
        var item = ToastItem(text: text, icon: icon, swatch: swatch)
        item.actionTitle = actionTitle
        item.action = action
        toasts.append(item)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        let id = item.id
        let life: UInt64 = actionTitle == nil ? 2_600_000_000 : 6_000_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: life)
            toasts.removeAll { $0.id == id }
        }
    }
}

/// Whether this Mac has a network path. Cloud models need one; the local model does not.
@MainActor
final class NetworkStatus: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "scribe.network"))
    }

    deinit { monitor.cancel() }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var search: SearchModel
    @StateObject private var recorder = Recorder()
    @StateObject private var network = NetworkStatus()

    /// Shown on top of the main area whenever a cloud model is chosen or a cloud job is running.
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
        GeometryReader { geo in
            ZStack {
                G.bg
                HStack(spacing: 0) {
                    SidebarView().frame(width: 248)
                    Rectangle().fill(G.border).frame(width: 1)
                    VStack(spacing: 0) {
                        if let warning { WarningBanner(text: warning).padding(.horizontal, 28).padding(.top, 16) }
                        router
                    }
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                GlobalSearch(width: geo.size.width * 0.4)
                if let modal = ui.modal { ModalLayer(modal: modal) }
                VStack(spacing: 8) {
                    Spacer().allowsHitTesting(false)
                    ForEach(ui.toasts) { ToastView(item: $0).transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                .padding(.bottom, 24)
                .animation(.easeOut(duration: 0.18), value: ui.toasts)
            }
        }
        .ignoresSafeArea()
        .environmentObject(recorder)
        .environmentObject(network)
        .foregroundStyle(G.text)
        .font(GFont.ui(14))
        .frame(minWidth: 940, minHeight: 660)
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "setupSkipped"), SetupItems(settings: settings).attentionCount > 0 {
                ui.section = .setup
            }
            Task { await settings.refreshStaleModels() }
        }
    }

    @ViewBuilder private var router: some View {
        switch ui.section {
        case .record: RecordView()
        case .importAudio: ImportView()
        case .library:
            if let id = ui.selection, let rec = store.recordings.first(where: { $0.id == id }) {
                DetailView(recording: rec).id(rec.id)
            } else {
                LibraryView()
            }
        case .settings: SettingsView()
        case .setup: SetupView()
        }
    }
}

// MARK: - First-run setup

/// What the first-run checklist looks at. Also decides whether it shows on launch.
@MainActor
struct SetupItems {
    let settings: AppSettings

    var whisperOK: Bool { FileManager.default.isExecutableFile(atPath: settings.whisperPath) }
    var modelOK: Bool { FileManager.default.fileExists(atPath: settings.localModelPath) }
    var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    var micDenied: Bool { micStatus == .denied || micStatus == .restricted }
    var screenOK: Bool { CGPreflightScreenCaptureAccess() }

    /// Items that stop something the user has asked for from working.
    var attentionCount: Int {
        var n = 0
        if !whisperOK { n += 1 }
        if !modelOK { n += 1 }
        if micDenied { n += 1 }
        if settings.captureSystemAudio && !screenOK { n += 1 }
        return n
    }
}

struct SetupView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState
    @State private var tick = 0

    var body: some View {
        let items = SetupItems(settings: settings)
        let attention = items.attentionCount
        VStack(alignment: .leading, spacing: 16) {
            LogoMark(size: 44)
            PageHeader(title: "Set up Scribe",
                       badge: AnyView(attention > 0
                                      ? StatusPill(kind: .warn, text: "\(attention) need\(attention == 1 ? "s" : "") attention")
                                      : StatusPill(kind: .ready, text: "All set"))) { EmptyView() }
            Text("Scribe records on this Mac and transcribes with a local model by default. Work through what needs attention, then check again.")
                .font(GFont.ui(14)).foregroundStyle(G.text2).lineSpacing(3).frame(maxWidth: 640, alignment: .leading)
            ScrollView {
                VStack(spacing: 0) {
                    row(icon: "terminal", title: "whisper-cli is installed",
                        detail: items.whisperOK ? "Found at \(settings.whisperPath)" : "Not found at \(settings.whisperPath). Install it with: brew install whisper-cpp",
                        state: items.whisperOK ? .ok : .attention, button: "Change path") { ui.openSettings(.local) }
                    row(icon: "cpu", title: "Local model file is present",
                        detail: items.modelOK ? "Found at \(settings.localModelPath)" : "Not found: \(settings.localModelPath)",
                        state: items.modelOK ? .ok : .attention, button: "Choose model file") { ui.openSettings(.local) }
                    row(icon: "mic", title: "Microphone permission",
                        detail: items.micDenied ? "Microphone access is off. Allow Scribe in System Settings."
                            : (items.micStatus == .authorized ? "Scribe can use the microphone." : "Scribe will ask the first time you record."),
                        state: items.micDenied ? .attention : (items.micStatus == .authorized ? .ok : .optional),
                        button: "Open System Settings") { openPrivacy("Privacy_Microphone") }
                    row(icon: "display", title: "Computer audio permission",
                        detail: items.screenOK ? "Scribe can capture computer audio."
                            : "Screen & System Audio Recording is off. It is needed to capture Teams and Meet. Quit and reopen Scribe after turning it on.",
                        state: items.screenOK ? .ok : (settings.captureSystemAudio ? .attention : .optional),
                        button: "Open System Settings") { openPrivacy("Privacy_ScreenCapture") }
                    row(icon: "key", title: "Cloud keys (optional)",
                        detail: "Gemini and ElevenLabs hear audio. Claude only reviews transcript text, because it cannot hear audio.",
                        state: .optional, button: "Open AI Models", last: true) { ui.openSettings(.models) }
                }
                .clippedCard()
            }
            .id(tick)
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    GIcon(attention > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle", size: 14)
                        .foregroundStyle(attention > 0 ? G.warnIcon : G.success)
                    Text(attention > 0 ? "\(attention) of 5 items need attention. Everything else is ready." : "Everything Scribe needs is ready.")
                        .font(GFont.ui(13)).foregroundStyle(G.text2)
                }
                Spacer()
                Button("Skip for now") { finish() }.buttonStyle(.g(.secondary, height: 36))
                Button { tick += 1 } label: { IconLabel("Check again", "arrow.clockwise") }
                    .buttonStyle(.g(.primary, height: 40))
                if attention == 0 {
                    Button("Start recording") { finish() }.buttonStyle(.g(.primary, height: 40))
                }
            }
        }
        .padding(.top, 24).padding(.horizontal, 28).padding(.bottom, 28)
    }

    private enum RowState { case ok, attention, optional }

    private func row(icon: String, title: String, detail: String, state: RowState, button: String,
                     last: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            IconTile(icon: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(GFont.ui(14, .semibold))
                Text(detail).font(GFont.ui(12)).foregroundStyle(G.text2).lineSpacing(2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                GIcon(state == .ok ? "checkmark.circle" : (state == .attention ? "exclamationmark.triangle.fill" : "minus.circle"), size: 14)
                Text(state == .ok ? "Ready" : (state == .attention ? "Needs attention" : "Optional"))
            }
            .font(GFont.ui(12, .semibold))
            .foregroundStyle(state == .ok ? G.success : (state == .attention ? G.warnIcon : G.text2))
            .frame(width: 132, alignment: .leading)
            Button(button, action: action).buttonStyle(.g(.secondary, height: 36)).frame(width: 168)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(G.border).frame(height: 1) } }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "setupSkipped")
        ui.goRecord()
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
