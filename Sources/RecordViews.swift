import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Shared pieces

/// A page whose content scrolls when the window is short but fills it when it is tall.
struct FillScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) { content.frame(minHeight: geo.size.height, alignment: .top) }
                .scrollIndicators(.hidden)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var badge: AnyView? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(GFont.ui(20, .semibold)).tracking(-0.4)
            if let badge { badge }
            if let subtitle { Text(subtitle).font(GFont.ui(13)).foregroundStyle(G.text3) }
            Spacer(minLength: 12)
            trailing
        }
        .frame(height: 36)
    }
}

/// A full-width notice with an icon, a title, a sentence and up to two buttons.
struct NoticeBanner<Actions: View>: View {
    let icon: String
    let title: String
    let text: String
    var danger = false
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            GIcon(icon, size: 16).foregroundStyle(danger ? G.danger : G.warnIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(GFont.ui(13, .semibold)).foregroundStyle(danger ? G.danger : G.warnText)
                Text(text).font(GFont.ui(13)).foregroundStyle(danger ? G.text2 : G.warnText).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(danger ? G.dangerSoft : G.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(danger ? G.danger : G.warnBorder))
    }
}

/// Numbered steps for fixing a macOS permission, with a button that opens the right System Settings pane.
struct PermissionCard: View {
    let title: String
    let text: String
    let steps: [String]
    let pane: String
    var onCheckAgain: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                GIcon("exclamationmark.triangle.fill", size: 16).foregroundStyle(G.warnIcon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(GFont.ui(14, .semibold)).foregroundStyle(G.warnText)
                    Text(text).font(GFont.ui(13)).foregroundStyle(G.warnText).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").font(GFont.mono(11, .medium)).foregroundStyle(G.warnText)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(G.warnBorder))
                        Text(s).font(GFont.ui(13)).foregroundStyle(G.warnText).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                } label: { IconLabel("Open System Settings", "gearshape") }
                .buttonStyle(.g(.secondary, height: 32))
                Button("Check again", action: onCheckAgain).buttonStyle(.g(.quiet, height: 32))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(G.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(G.warnBorder))
    }
}

/// Menu that picks the folder new recordings go into.
struct FolderMenu: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var ui: UIState
    var fullWidth = false

    var body: some View {
        Menu {
            Button("Library (top level)") { ui.folder = nil }
            Divider()
            ForEach(store.flatFolders(), id: \.folder.id) { item in
                Button(item.path) { ui.folder = item.folder.id }
            }
        } label: {
            GMenuLabel(content: AnyView(
                HStack(spacing: 8) {
                    if let f = store.folder(ui.folder) { FolderSwatch(color: f.color.swiftUI) }
                    else { GIcon("tray.full", size: 12).foregroundStyle(G.text3) }
                    Text(store.path(of: ui.folder)).lineLimit(1)
                    if fullWidth { Spacer(minLength: 0) }
                    GIcon("chevron.down", size: 10, weight: .semibold).foregroundStyle(G.text3)
                }), height: fullWidth ? 40 : 34)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .help("Folder for new recordings and imports")
    }
}

/// Local or Cloud, then the model cards and, for a cloud provider, the model picker from the catalog.
struct ModelChooser: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState
    /// Length of the recording this is for, when known, so the speaker-label limit can warn.
    var recordingSeconds: Double? = nil
    @State private var cloudPick: ProviderKind = .gemini

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Transcription model")
            GSegmented(options: [false, true],
                       selection: Binding(get: { settings.primary.isCloud },
                                          set: { settings.primary = $0 ? cloudPick : .local }),
                       title: { $0 ? "Cloud" : "Local" },
                       icon: { $0 ? "cloud" : "cpu" },
                       label: "Where to transcribe")
            if settings.primary.isCloud {
                ForEach([ProviderKind.gemini, .elevenlabs]) { k in
                    RadioCard(selected: settings.primary == k, action: { settings.primary = k; cloudPick = k }) {
                        cloudCard(k)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("\(settings.primary.short) model")
                    ModelPicker(kind: settings.primary, recordingSeconds: recordingSeconds, compact: true)
                }
                .padding(.top, 6)
            } else {
                RadioCard(selected: true, action: {}) { localCard }
            }
        }
        .onAppear { if settings.primary.isCloud { cloudPick = settings.primary } }
    }

    private var localCard: some View {
        let issue = settings.issue(for: .local)
        let english = settings.callLanguage == .english
        return VStack(alignment: .leading, spacing: 4) {
            Text(english ? "English model" : "Hindi + English model").font(GFont.ui(14, .semibold))
            Text(english ? "Whisper large-v3, strong at English. Runs on this Mac."
                         : "Handles mixed Hindi and English. Runs on this Mac.")
                .font(GFont.ui(12)).foregroundStyle(G.text2).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            statusLine(issue: issue, ok: "Model file found")
        }
    }

    private func cloudCard(_ k: ProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k.title).font(GFont.ui(14, .semibold))
            Text(k == .gemini ? "Fast, handles mixed Hindi and English well." : "Strong speaker labels and word timing.")
                .font(GFont.ui(12)).foregroundStyle(G.text2).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            statusLine(issue: settings.issue(for: k), ok: "API key and model set")
        }
    }

    private func statusLine(issue: String?, ok: String) -> some View {
        Group {
            if let issue {
                Button { ui.openSettings(settings.primary.isCloud ? .cloud(settings.primary) : .local) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        GIcon("exclamationmark.triangle.fill", size: 11).foregroundStyle(G.warnIcon).padding(.top, 2)
                        Text(issue).font(GFont.ui(12, .semibold)).foregroundStyle(G.warnIcon)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .buttonStyle(.plain)
                .help("Open AI Models")
            } else {
                HStack(spacing: 6) {
                    GIcon("checkmark", size: 11, weight: .bold)
                    Text(ok).font(GFont.ui(12, .semibold))
                }
                .foregroundStyle(G.success)
            }
        }
        .padding(.top, 2)
    }
}

struct CallLanguageField: View {
    @EnvironmentObject var settings: AppSettings
    var disabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Call language, you can change it after")
            GSegmented(options: CallLanguage.allCases, selection: $settings.callLanguage, title: { $0.title },
                       label: "Call language")
                .disabled(disabled)
                .help("English only uses English-specific models. Hindi + English uses the code-switching model.")
        }
    }
}

// MARK: - Record

struct RecordView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var network: NetworkStatus
    @State private var notice: String?
    @State private var recheck = 0
    @State private var keyMonitor: Any?

    private var issue: String? { settings.issue(for: settings.primary) }
    private var offline: Bool { settings.primary.isCloud && !network.isOnline }
    /// The sources this recording uses: the live ones while recording, the chosen ones before.
    private var usesMic: Bool { recorder.isRecording ? recorder.hasMic : settings.captureMicrophone }
    private var usesSystem: Bool { recorder.isRecording ? recorder.hasSystemAudio : settings.captureSystemAudio }
    private var noSource: Bool { !settings.captureMicrophone && !settings.captureSystemAudio }
    private var sourcesLine: String {
        switch (usesMic, usesSystem) {
        case (true, true): return "Microphone and computer audio"
        case (false, true): return "Computer audio"
        default: return "Microphone"
        }
    }

    private var micBlocked: Bool {
        guard usesMic else { return false }
        if recorder.micDenied { return true }
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }
    private var micStatus: (text: String, ok: Bool) {
        if micBlocked { return (recorder.isRecording ? "No access" : "Access off", false) }
        if recorder.isRecording { return ("Recording", true) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return ("Allowed", true)
        default: return ("Asked on first use", true)
        }
    }

    private var recordingPillText: String {
        if !recorder.hasMic { return "Recording, computer audio only" }
        return recorder.hasSystemAudio || !settings.captureSystemAudio ? "Recording" : "Recording, microphone only"
    }

    private var pill: AnyView {
        if recorder.isRecording {
            return AnyView(recorder.isPaused
                ? StatusPill(kind: .neutral, text: "Paused", icon: "pause.fill")
                : StatusPill(kind: .ready, text: recordingPillText, icon: "circle.fill"))
        }
        if noSource { return AnyView(StatusPill(kind: .warn, text: "No source on")) }
        if micBlocked { return AnyView(StatusPill(kind: .bad, text: "Microphone off")) }
        if offline { return AnyView(StatusPill(kind: .warn, text: "Offline", icon: "wifi.slash")) }
        if let issue {
            let text = issue.lowercased().contains("api key") ? "Needs API key"
                : (issue.lowercased().contains("model file") ? "Model file missing" : "Needs attention")
            return AnyView(StatusPill(kind: .warn, text: text))
        }
        return AnyView(StatusPill(kind: .ready, text: "Ready"))
    }

    var body: some View {
        if let saved = ui.justSaved, !recorder.isRecording {
            SavedRecordingView(saved: saved)
        } else {
            live
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "New recording", badge: pill) {
                HStack(spacing: 12) {
                    Text("Saving to").font(GFont.ui(13)).foregroundStyle(G.text3)
                    FolderMenu().disabled(recorder.isRecording)
                }
            }
            banners
            HStack(alignment: .top, spacing: 16) {
                setupCard.frame(width: 352)
                captureCard.frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 24).padding(.horizontal, 28).padding(.bottom, 28)
        .id(recheck)
        .onAppear { installSpaceKey() }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Space pauses and resumes a running recording, unless a text field is being edited or a dialog is open.
    /// It does nothing when no recording is running, so Space can never start or stop one.
    private func installSpaceKey() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        let recorder = recorder, ui = ui
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                guard recorder.isRecording, ui.section == .record, ui.modal == nil else { return false }
                let responder = NSApp.keyWindow?.firstResponder
                if responder is NSText || responder is NSTextField { return false }
                recorder.togglePause()
                return true
            }
            return handled ? nil : event
        }
    }

    @ViewBuilder private var banners: some View {
        if offline {
            NoticeBanner(icon: "wifi.slash", title: "You are offline",
                         text: "\(settings.name(settings.primary)) needs an internet connection, so this recording cannot be transcribed in the cloud. The local model runs on this Mac with no connection.") {
                Button("Switch to local") { settings.primary = .local; ui.toast("Local model selected", icon: "cpu") }
                    .buttonStyle(.g(.secondary, height: 32))
            }
        } else if settings.primary == .local, let issue, !recorder.isRecording {
            NoticeBanner(icon: "exclamationmark.triangle.fill",
                         title: issue.lowercased().contains("model file") ? "Local model file is missing." : "The local model is not ready.",
                         text: "You can still record and the audio is saved. Transcribing will not start until this is fixed or you pick another model. \(issue)") {
                Button("Fix in AI Models") { ui.openSettings(.local) }.buttonStyle(.g(.secondary, height: 32))
            }
        }
    }

    // MARK: Setup card

    private var setupCard: some View {
        FillScroll {
            VStack(alignment: .leading, spacing: 22) {
                if recorder.isRecording {
                    HStack(spacing: 8) {
                        GIcon("lock.fill", size: 11)
                        Text(recorder.isPaused ? "Setup is locked until you stop" : "Setup is locked while recording")
                            .font(GFont.ui(12, .semibold))
                    }
                    .foregroundStyle(G.text2)
                }
                ModelChooser().disabled(recorder.isRecording)
                CallLanguageField(disabled: recorder.isRecording)
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Sources")
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            GCheckbox(isOn: $settings.captureMicrophone).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Capture microphone").font(GFont.ui(14, .semibold))
                                Text(settings.captureMicrophone ? "Default input" : "Off: only computer audio is recorded.")
                                    .font(GFont.ui(12)).foregroundStyle(G.text2)
                            }
                            .onTapGesture { settings.captureMicrophone.toggle() }
                            Spacer()
                            if settings.captureMicrophone {
                                HStack(spacing: 5) {
                                    GIcon(micStatus.ok ? "checkmark" : "exclamationmark.triangle.fill", size: 11, weight: .bold)
                                    Text(micStatus.text).font(GFont.ui(12, .semibold))
                                }
                                .foregroundStyle(micStatus.ok ? G.success : G.warnIcon)
                            }
                        }
                        .disabled(recorder.isRecording)
                        .help("Turn off to record only what this Mac plays, for example a webinar.")
                        if settings.captureMicrophone {
                            HStack(alignment: .top, spacing: 12) {
                                GCheckbox(isOn: $settings.echoCancellation).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Remove speaker echo").font(GFont.ui(14, .semibold))
                                    Text("Stops the microphone recording the call a second time from your speakers. Uses Apple's echo cancellation, like FaceTime.")
                                        .font(GFont.ui(12)).foregroundStyle(G.text2).lineSpacing(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .onTapGesture { settings.echoCancellation.toggle() }
                            }
                            .padding(.leading, 28)
                            .disabled(recorder.isRecording)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            GCheckbox(isOn: $settings.captureSystemAudio).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Capture computer audio").font(GFont.ui(14, .semibold))
                                Text(settings.captureMicrophone && !settings.echoCancellation
                                     ? "Teams, Meet, or any app that plays sound. Use headphones so the microphone does not pick it up twice."
                                     : "Teams, Meet, or any app that plays sound.")
                                    .font(GFont.ui(12)).foregroundStyle(G.text2).lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .onTapGesture { settings.captureSystemAudio.toggle() }
                        }
                        .disabled(recorder.isRecording)
                        .help("Captures everything this Mac plays. Use headphones so the microphone does not pick up the speakers a second time.")
                        if noSource && !recorder.isRecording {
                            HStack(spacing: 6) {
                                GIcon("exclamationmark.triangle.fill", size: 11)
                                Text("Both sources are off. Turn on at least one to record.")
                            }
                            .font(GFont.ui(12, .semibold)).foregroundStyle(G.warnIcon)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
                }
            }
            .padding(20)
        }
        .clippedCard()
    }

    // MARK: Live capture card

    private var captureCard: some View {
        FillScroll {
            VStack(spacing: 14) {
                HStack {
                    HStack(spacing: 8) {
                        GIcon(settings.primary.isCloud ? "cloud" : "cpu", size: 13)
                        Text(modelLine)
                    }
                    .font(GFont.ui(13)).foregroundStyle(G.text2)
                    Spacer()
                    Text(settings.callLanguage.title + (recorder.isRecording && !(usesMic && usesSystem) ? ", \(sourcesLine.lowercased()) only" : ""))
                        .font(GFont.ui(13)).foregroundStyle(G.text2)
                }
                Text(clockString(recorder.elapsed))
                    .font(GFont.mono(68, .medium)).tracking(-2)
                    .foregroundStyle(recorder.isRecording ? G.text : G.text3)
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Elapsed time \(formatTime(recorder.elapsed))")
                let live = recorder.isRecording && !recorder.isPaused
                if usesMic {
                    CaptureLane(title: "Microphone", icon: "mic", iconColor: G.accentText,
                                state: laneState, levels: recorder.micLevels, active: live, tint: G.accent, seed: 1.3)
                } else if recorder.isRecording {
                    Text("Microphone is off for this recording. Only computer audio is captured.")
                        .font(GFont.ui(12)).foregroundStyle(G.text3).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                if usesSystem {
                    CaptureLane(title: "Computer audio", icon: "display", iconColor: G.blue,
                                state: laneState, levels: recorder.systemLevels, active: live, tint: G.blue, seed: 4.1)
                } else if recorder.isRecording {
                    Text("Computer audio is off for this recording. Turn it on before you start to capture Teams, Meet or any app that plays sound.")
                        .font(GFont.ui(12)).foregroundStyle(G.text3).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 8)
                controls
                messages
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    GIcon(settings.primary.isCloud ? "cloud" : "lock.shield", size: 12)
                    Text(recorder.isPaused ? "Nothing is captured while paused. Resume to keep recording into the same file."
                         : (settings.primary.isCloud
                            ? "The selected model is in the cloud. Choose Local to keep audio on this Mac."
                            : "Local model selected. Audio stays on this Mac."))
                }
                .font(GFont.ui(12)).foregroundStyle(G.text3)
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .clippedCard()
    }

    private var modelLine: String {
        let name = settings.primary == .local
            ? (settings.callLanguage == .english ? "English model" : "Hindi + English model")
            : settings.name(settings.primary)
        return name + (settings.primary.isCloud ? ", cloud" : ", local")
    }

    private var laneState: String {
        if recorder.isPaused { return "Paused" }
        return recorder.isRecording ? "Recording" : "Waiting to start"
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 28) {
                if recorder.isRecording {
                    // Same footprint as the stop button (100pt ring, 84pt disc), neutral so it never reads as Stop.
                    Button { recorder.togglePause() } label: {
                        ZStack {
                            Circle().strokeBorder(G.borderStrong, lineWidth: 2).frame(width: 100, height: 100)
                            Circle().fill(G.surface2).frame(width: 84, height: 84)
                            GIcon(recorder.isPaused ? "play.fill" : "pause.fill", size: 30)
                                .foregroundStyle(G.text)
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(recorder.isPaused ? "Resume (Space)" : "Pause (Space)")
                    .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")
                }
                Button(action: toggleRecording) {
                    ZStack {
                        Circle().strokeBorder(G.accent, lineWidth: 2).frame(width: 100, height: 100)
                        Circle().fill(G.accent).frame(width: 84, height: 84)
                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(G.onAccent).frame(width: 26, height: 26)
                        } else {
                            Circle().fill(G.onAccent).frame(width: 28, height: 28)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // Stop is click-only so a stray key can never end a call. ⌘R only starts a recording,
                // and the button never takes keyboard focus, so Space or Return cannot press it either.
                .focusable(false)
                .keyboardShortcut(recorder.isRecording ? nil : KeyboardShortcut("r", modifiers: [.command]))
                .disabled(!recorder.isRecording && noSource)
                .opacity(!recorder.isRecording && noSource ? 0.4 : 1)
                .help(recorder.isRecording ? "Stop and transcribe (click)"
                      : (noSource ? "Turn on the microphone or computer audio first" : "Start recording (⌘R)"))
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
            }
            Text(recorder.isRecording ? "Stop and transcribe" : (noSource ? "Turn on a source to record" : "Start recording"))
                .font(GFont.ui(13, .medium)).foregroundStyle(G.text2)
            Button { ui.section = .importAudio } label: { IconLabel("Import audio file", "square.and.arrow.down") }
                .buttonStyle(.g(.secondary, height: 36))
                .disabled(recorder.isRecording)
                .padding(.top, 4)
        }
    }

    @ViewBuilder private var messages: some View {
        VStack(spacing: 8) {
            if micBlocked {
                PermissionCard(title: "Microphone access is off",
                               text: "Scribe cannot hear the microphone, so recording cannot start. Allow Scribe in System Settings, Privacy & Security, Microphone.",
                               steps: ["Open System Settings, then Privacy & Security.", "Choose Microphone and switch Scribe on.",
                                       "Come back here and press Start recording."],
                               pane: "Privacy_Microphone") {
                    recorder.micDenied = false
                    recheck += 1
                }
            }
            if recorder.screenDenied {
                PermissionCard(title: "Computer audio needs permission",
                               text: settings.captureMicrophone
                                   ? "Scribe does not have Screen & System Audio Recording access, so this recording falls back to the microphone only."
                                   : "Scribe does not have Screen & System Audio Recording access, and the microphone is off, so recording cannot start.",
                               steps: ["Open System Settings, then Privacy & Security.",
                                       "Choose Screen & System Audio Recording and switch Scribe on.",
                                       "Quit and reopen Scribe, then record again."],
                               pane: "Privacy_ScreenCapture") {
                    recorder.screenDenied = false
                    recheck += 1
                }
            }
            if let message = recorder.errorMessage { inlineMessage(message, danger: false) }
            if let notice { inlineMessage(notice, danger: true) }
        }
    }

    private func inlineMessage(_ text: String, danger: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            GIcon(danger ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill", size: 13)
                .foregroundStyle(danger ? G.danger : G.warnIcon)
            Text(text).font(GFont.ui(13)).foregroundStyle(danger ? G.danger : G.warnText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(danger ? G.dangerSoft : G.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(danger ? G.danger : G.warnBorder))
    }

    private func toggleRecording() {
        notice = nil
        if recorder.isRecording {
            let sources = sourcesLine
            Task {
                let duration = await recorder.stop()
                guard let p = ui.pending else { return }
                ui.pending = nil
                let title = "Recording " + Date().formatted(date: .abbreviated, time: .shortened)
                let rec = store.create(id: p.id, title: title, audioFile: p.url.lastPathComponent, duration: duration,
                                       language: settings.callLanguage, folderID: ui.folder)
                let kind = settings.primary
                // Do not transcribe yet: during a call people often do not know which language is being
                // used, so the next screen asks, and transcription starts only when they confirm.
                ui.justSaved = SavedRecording(id: rec.id, provider: kind,
                                              sources: sources)
            }
        } else {
            ui.justSaved = nil
            let id = UUID().uuidString
            let url = store.newAudioURL(id: id, ext: "m4a")
            ui.pending = PendingRecording(id: id, url: url)
            Task {
                if await recorder.start(to: url, withMic: settings.captureMicrophone,
                                        withSystemAudio: settings.captureSystemAudio,
                                        echoCancel: settings.echoCancellation) == false {
                    ui.pending = nil
                    store.delete(id)
                    if !recorder.micDenied && !recorder.screenDenied && recorder.errorMessage == nil { notice = "Could not start recording." }
                }
            }
        }
    }
}

// MARK: - Recording saved

/// Shown after Stop: the recording is safe, and the transcription steps are visible as they happen.
struct SavedRecordingView: View {
    let saved: SavedRecording
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner
    @EnvironmentObject var ui: UIState

    private enum Step { case done, active, pending, failed }
    private var recording: Recording? { store.recordings.first { $0.id == saved.id } }

    var body: some View {
        let rec = recording
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Recording stopped", badge: AnyView(StatusPill(kind: .ready, text: "Saved"))) { EmptyView() }
            HStack(alignment: .top, spacing: 16) {
                summary(rec).frame(width: 352)
                if isChoosing(rec) { chooseLanguage(rec).frame(maxWidth: .infinity) } else { steps(rec).frame(maxWidth: .infinity) }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 24).padding(.horizontal, 28).padding(.bottom, 28)
    }

    private func summary(_ rec: Recording?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Saved recording")
            VStack(alignment: .leading, spacing: 4) {
                Text(rec?.title ?? "Recording").font(GFont.ui(16, .semibold))
                Text("You can rename it later in the Library.").font(GFont.ui(13)).foregroundStyle(G.text2)
            }
            VStack(spacing: 0) {
                row("Length", formatTime(rec?.duration ?? 0), mono: true)
                row("Language", rec?.callLanguage.title ?? "")
                row("Sources", saved.sources)
                row("Model", settings.name(saved.provider, language: rec?.callLanguage))
                row("Saved to", store.path(of: rec?.folderID), last: true)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                GIcon("lock.shield", size: 12)
                Text("Library folder, audio file kept on this Mac").font(GFont.ui(12))
            }
            .foregroundStyle(G.text3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 0)
    }

    private func row(_ k: String, _ v: String, mono: Bool = false, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(GFont.ui(12)).foregroundStyle(G.text3).frame(width: 80, alignment: .leading)
            Text(v).font(mono ? GFont.mono(13) : GFont.ui(13)).foregroundStyle(G.text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(G.border).frame(height: 1) } }
    }

    /// True until a transcription for this recording has started, finished or failed.
    private func isChoosing(_ rec: Recording?) -> Bool {
        let hasResult = rec?.results.contains { $0.provider == saved.provider } ?? false
        return !hasResult && !jobs.isRunning(saved.id, saved.provider)
            && jobs.progress(saved.id, saved.provider) == nil && jobs.error(saved.id, saved.provider) == nil
    }

    private func languageBinding(_ rec: Recording?) -> Binding<CallLanguage> {
        Binding(get: { rec?.callLanguage ?? settings.callLanguage }, set: { store.setLanguage(saved.id, $0) })
    }

    private func chooseLanguage(_ rec: Recording?) -> some View {
        let lang = rec?.callLanguage ?? settings.callLanguage
        let kind = saved.provider
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which language was this call?").font(GFont.ui(18, .semibold)).tracking(-0.2)
                Text("Transcription has not started. Listen if you are unsure, then pick the language so the right model is used.")
                    .font(GFont.ui(13)).foregroundStyle(G.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GSegmented(options: CallLanguage.allCases, selection: languageBinding(rec), title: { $0.title },
                       label: "Call language")
                .frame(maxWidth: 360)
            VStack(alignment: .leading, spacing: 6) {
                Text(lang == .english
                     ? "English only. Uses the English model, which is faster and more accurate when nobody speaks Hindi."
                     : "Hindi and English in the same call. Uses the Hindi plus English model.")
                    .font(GFont.ui(13)).foregroundStyle(G.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    GIcon(kind.isCloud ? "cloud" : "cpu", size: 12)
                    Text(settings.name(kind, language: lang)).font(GFont.mono(12))
                }
                .foregroundStyle(G.text3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button { startTranscription(rec, kind) } label: { IconLabel("Start transcription", "waveform") }
                    .buttonStyle(.g(.primary, height: 40)).keyboardShortcut(.defaultAction)
                Button { ui.justSaved = nil; ui.open(recording: saved.id, folder: rec?.folderID) } label: {
                    IconLabel("Not now, open in Library", "folder")
                }
                .buttonStyle(.g(.secondary, height: 40))
            }
            Text("You can transcribe later from the Library, and pick the language again there.")
                .font(GFont.ui(12)).foregroundStyle(G.text3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 0)
    }

    private func startTranscription(_ rec: Recording?, _ kind: ProviderKind) {
        guard let rec = store.recordings.first(where: { $0.id == saved.id }) ?? rec else { return }
        if settings.issue(for: kind, language: rec.callLanguage) == nil, kind.isCloud {
            ui.modal = .confirmCloud(rec, kind)        // the confirmation starts the job
        } else {
            jobs.start(rec, kind: kind)                // also records a "not ready" message as an error
        }
    }

    private func steps(_ rec: Recording?) -> some View {
        let p = jobs.progress(saved.id, saved.provider)
        let running = jobs.isRunning(saved.id, saved.provider)
        let err = jobs.error(saved.id, saved.provider)
        let hasResult = rec?.results.contains { $0.provider == saved.provider } ?? false
        let prepared: Step = hasResult || (p != nil && p?.stage != .preparing) ? .done : (running ? .active : (err != nil ? .failed : .pending))
        let transcribing: Step = hasResult ? .done : (err != nil ? .failed : (running && prepared == .done ? .active : .pending))
        let ready: Step = hasResult ? .done : .pending
        let title = hasResult ? "Transcript ready" : (err != nil ? "Transcription failed" : "Saved, transcribing")

        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(GFont.ui(18, .semibold)).tracking(-0.2)
                Text(err ?? "Your recording is safe in the Library. Transcribing can take a while for long recordings.")
                    .font(GFont.ui(13)).foregroundStyle(err == nil ? G.text2 : G.danger).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 16) {
                stepRow("Audio saved", "\(saved.sources) mixed into one file, \(formatTime(rec?.duration ?? 0)) long.", .done)
                stepRow("Audio prepared", "Converted to the format the model reads.", prepared)
                stepRow("Transcribing", saved.provider.isCloud ? "\(saved.provider.company) is working on it."
                        : "The local model is running on this Mac. Nothing leaves this device.", transcribing) {
                    if transcribing == .active { MiniProgress(progress: p).frame(maxWidth: 260) }
                }
                stepRow("Transcript ready", "It opens in the Library when it is finished.", ready)
            }
            Spacer(minLength: 0)
            Text("You can leave this screen. Transcribing keeps running.").font(GFont.ui(12)).foregroundStyle(G.text3)
            HStack(spacing: 10) {
                Button { ui.justSaved = nil; ui.open(recording: saved.id, folder: rec?.folderID) } label: {
                    IconLabel("Open in Library", "folder")
                }
                .buttonStyle(.g(.primary, height: 40)).keyboardShortcut(.defaultAction)
                Button { ui.justSaved = nil } label: { IconLabel("New recording", "mic") }
                    .buttonStyle(.g(.secondary, height: 40))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 0)
    }

    private func stepRow<Extra: View>(_ title: String, _ text: String, _ state: Step,
                                      @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().strokeBorder(state == .pending ? G.borderStrong : (state == .failed ? G.danger : G.accentText), lineWidth: 1.5)
                switch state {
                case .done: GIcon("checkmark", size: 9, weight: .heavy).foregroundStyle(G.accentText)
                case .active: Circle().fill(G.accentText).padding(6)
                case .failed: GIcon("xmark", size: 9, weight: .heavy).foregroundStyle(G.danger)
                case .pending: EmptyView()
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(GFont.ui(14, .semibold)).foregroundStyle(state == .pending ? G.text3 : G.text)
                Text(text).font(GFont.ui(12)).foregroundStyle(G.text2).fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
    }
}

// MARK: - Import

struct ImportView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var jobs: JobRunner
    @EnvironmentObject var ui: UIState
    @State private var chosen: URL?
    @State private var chosenSeconds: Double = 0
    @State private var targeted = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Import audio", subtitle: chosen == nil ? "Transcribe a recording you already have." : nil,
                       badge: chosen == nil ? nil : AnyView(StatusPill(kind: .ready, text: "File chosen"))) { EmptyView() }
            HStack(alignment: .top, spacing: 16) {
                FillScroll {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Destination folder")
                            FolderMenu(fullWidth: true)
                        }
                        CallLanguageField()
                        ModelChooser(recordingSeconds: chosen == nil ? nil : chosenSeconds)
                    }
                    .padding(20)
                }
                .clippedCard()
                .frame(width: 352)
                dropZone.frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 24).padding(.horizontal, 28).padding(.bottom, 28)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(targeted ? G.accent : G.borderStrong, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(targeted ? G.accentSoft : Color.clear))
            VStack(spacing: 14) {
                if let chosen { chosenFile(chosen) } else { emptyZone }
                if let notice {
                    Text(notice).font(GFont.ui(13)).foregroundStyle(G.danger).multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
        .padding(20)
        .clippedCard()
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { choose(url) } }
            }
            return true
        }
    }

    private var emptyZone: some View {
        VStack(spacing: 14) {
            GIcon(targeted ? "arrow.down.doc" : "square.and.arrow.up", size: 28).foregroundStyle(targeted ? G.accentText : G.text2)
                .frame(width: 72, height: 72)
                .background(Circle().fill(targeted ? G.accentSoft : G.surface2))
                .overlay(Circle().strokeBorder(targeted ? G.accent : G.borderStrong))
            Text(targeted ? "Release to choose this file" : "Drop an audio file here")
                .font(GFont.ui(20, .semibold)).tracking(-0.4)
            Text(targeted ? "Drop it anywhere in this area. You can review the details before transcribing starts."
                 : "Drag a recording from Finder, or choose one from your Mac. Scribe copies it into your library, so the original stays where it is.")
                .font(GFont.ui(14)).foregroundStyle(G.text2).lineSpacing(3)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            if !targeted {
                Button(action: chooseFile) { IconLabel("Choose file", "folder") }
                    .buttonStyle(.g(.primary, height: 44))
                    .padding(.top, 6)
                VStack(spacing: 8) {
                    SectionLabel("Supported formats")
                    HStack(spacing: 6) {
                        ForEach(["M4A", "MP3", "WAV", "AAC", "AIFF", "FLAC", "CAF"], id: \.self) { Chip(text: $0, mono: true) }
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func chosenFile(_ url: URL) -> some View {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        let kind = url.pathExtension.isEmpty ? "Audio file" : "\(url.pathExtension.uppercased()) audio file"
        return VStack(spacing: 16) {
            GIcon("waveform", size: 28).foregroundStyle(G.accentText)
                .frame(width: 72, height: 72)
                .background(Circle().fill(G.accentSoft))
            VStack(spacing: 4) {
                Text(url.lastPathComponent).font(GFont.ui(18, .semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text("\(kind), \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                    .font(GFont.ui(13)).foregroundStyle(G.text2)
            }
            VStack(spacing: 0) {
                detail("Length", chosenSeconds > 0 ? clockString(chosenSeconds) : "Unknown", mono: true)
                detail("Model", settings.name(settings.primary))
                detail("Language", settings.callLanguage.title)
                detail("Saving to", store.path(of: ui.folder), last: true)
            }
            .frame(maxWidth: 380)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
            HStack(spacing: 10) {
                Button("Choose another file", action: chooseFile).buttonStyle(.g(.secondary, height: 40))
                Button { importChosen(url) } label: { IconLabel("Start transcription", "text.badge.checkmark") }
                    .buttonStyle(.g(.primary, height: 40))
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 8) {
                GIcon(settings.primary.isCloud ? "cloud" : "lock.shield", size: 12)
                Text(settings.primary.isCloud ? "The selected model is in the cloud. The audio will be sent to \(settings.primary.company)."
                     : "Local model selected. Audio stays on this Mac.")
            }
            .font(GFont.ui(12)).foregroundStyle(G.text3)
        }
    }

    private func detail(_ k: String, _ v: String, mono: Bool = false, last: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(GFont.ui(12)).foregroundStyle(G.text3).frame(width: 80, alignment: .leading)
            Text(v).font(mono ? GFont.mono(13) : GFont.ui(13)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(G.border).frame(height: 1) } }
    }

    private func choose(_ url: URL) {
        notice = nil
        if let type = UTType(filenameExtension: url.pathExtension), !type.conforms(to: .audio) {
            notice = "That file is not audio."
            return
        }
        chosenSeconds = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
        chosen = url
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to transcribe"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url)
    }

    private func importChosen(_ url: URL) {
        notice = nil
        do {
            let rec = try store.importAudio(from: url, language: settings.callLanguage, folderID: ui.folder)
            chosen = nil
            ui.open(recording: rec.id, folder: rec.folderID)
            jobs.start(rec, kind: settings.primary)
        } catch {
            notice = "Could not import that file: \(error.localizedDescription)"
        }
    }
}
