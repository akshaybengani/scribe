import SwiftUI
import AppKit

/// Settings as pages: an overview of the four providers, one page per provider, output, and storage.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState

    private enum Top: Hashable { case models, output, storage }

    private var top: Top {
        switch ui.settingsPage {
        case .models, .local, .cloud: return .models
        case .output: return .output
        case .storage: return .storage
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Settings") {
                Button("Done") { ui.closeSettings() }
                    .buttonStyle(.g(.secondary, height: 36))
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 2) {
                    navItem("AI Models", "cpu", on: top == .models) { ui.settingsPage = .models }
                    navItem("Output", "doc.text", on: top == .output) { ui.settingsPage = .output }
                    navItem("Storage and privacy", "lock.shield", on: top == .storage) { ui.settingsPage = .storage }
                }
                .frame(width: 212)
                ScrollView {
                    page
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 24).padding(.horizontal, 28).padding(.bottom, 20)
    }

    @ViewBuilder private var page: some View {
        switch ui.settingsPage {
        case .models: ModelsOverviewPage()
        case .local: LocalModelPage()
        case .cloud(let k): CloudProviderPage(kind: k).id(k)
        case .output: OutputPage()
        case .storage: StoragePage()
        }
    }

    private func navItem(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                GIcon(icon, size: 14).frame(width: 18)
                Text(title).font(GFont.ui(14, .medium))
                Spacer()
            }
            .foregroundStyle(on ? G.text : G.text2)
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? G.surface2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Shared page pieces

/// Names the provider the way the settings pages do.
func providerName(_ k: ProviderKind) -> String { k == .local ? "Local (whisper.cpp)" : k.title }

/// The one sentence of the cloud warning for a single provider.
func cloudNotice(_ k: ProviderKind) -> String {
    k.hearsAudio
        ? "Cloud model in use: audio will be sent to \(k.company), a third-party platform, for processing."
        : "Cloud model in use: transcript text, not audio, will be sent to \(k.company), a third-party platform, for processing."
}

private struct PageTitle: View {
    let title: String
    var body: some View { Text(title).font(GFont.ui(20, .semibold)).tracking(-0.4) }
}

private struct Breadcrumb: View {
    let title: String
    @EnvironmentObject var ui: UIState
    var body: some View {
        HStack(spacing: 8) {
            Button { ui.settingsPage = .models } label: {
                Text("AI Models").foregroundStyle(G.blue).font(GFont.ui(13, .medium))
            }
            .buttonStyle(.plain)
            Text("/").foregroundStyle(G.text3)
            Text(title).foregroundStyle(G.text2)
        }
        .font(GFont.ui(13))
    }
}

private func readinessPill(_ issue: String?) -> some View {
    Group {
        if issue == nil { StatusPill(kind: .ready, text: "Ready", icon: "checkmark.circle") }
        else { StatusPill(kind: .warn, text: "Needs attention") }
    }
    .help(issue ?? "Ready")
}

private struct CloudTag: View {
    var text = "Cloud"
    var body: some View {
        HStack(spacing: 4) { GIcon("cloud", size: 11); Text(text) }
            .font(GFont.ui(12)).foregroundStyle(G.warnIcon)
    }
}

@MainActor private func chooseFile(message: String, current: String, set: @escaping (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.directoryURL = AppSettings.modelsFolder
    panel.message = message
    if panel.runModal() == .OK, let url = panel.url { set(url.path) }
}

// MARK: - AI Models overview

private struct ModelsOverviewPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                PageTitle(title: "AI Models")
                Text("Each provider shows whether it is ready. Cloud providers need an API key, which is kept in your Keychain.")
                    .font(GFont.ui(14)).foregroundStyle(G.text2).lineSpacing(3)
            }
            .padding(.bottom, 4)
            ForEach(ProviderKind.allCases) { k in providerCard(k) }
            HStack(spacing: 10) {
                GIcon("lock", size: 13)
                Text("API keys are stored in the macOS Keychain, never in a file.")
            }
            .font(GFont.ui(13)).foregroundStyle(G.text3).padding(.top, 4)
        }
    }

    private func providerCard(_ k: ProviderKind) -> some View {
        let issue = settings.issue(for: k)
        let model = settings.config().model(k, settings.callLanguage)
        let caption: String
        switch k {
        case .local: caption = "Private: audio never leaves this Mac and no internet is needed."
        case .gemini, .elevenlabs: caption = "Audio is uploaded to \(k.company)."
        case .claude: caption = "Reads transcripts you already have. Only the text is sent to Anthropic."
        }
        return HStack(spacing: 16) {
            IconTile(icon: k.isCloud ? "cloud" : "cpu")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(providerName(k)).font(GFont.ui(15, .semibold))
                    if k.isCloud { CloudTag(text: k.hearsAudio ? "Cloud" : "Cloud, text only") }
                }
                Text("Model: \(model)").font(GFont.mono(12)).foregroundStyle(G.text2).lineLimit(1)
                Text(issue ?? caption).font(GFont.ui(12, issue == nil ? .regular : .medium))
                    .foregroundStyle(issue == nil ? G.text3 : G.warnIcon).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            readinessPill(issue)
            Button { ui.settingsPage = k == .local ? .local : .cloud(k) } label: { IconLabel("Edit", "pencil") }
                .buttonStyle(.g(.secondary, height: 36))
                .accessibilityLabel("Edit \(providerName(k))")
        }
        .card(padding: 16)
    }
}

// MARK: - Local model

private struct LocalModelPage: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Breadcrumb(title: "Local (whisper.cpp)")
            HStack(spacing: 12) {
                PageTitle(title: "Local (whisper.cpp)")
                readinessPill(settings.issue(for: .local))
            }
            Text("Private: audio never leaves this Mac and no internet is needed.")
                .font(GFont.ui(14)).foregroundStyle(G.text2)

            VStack(alignment: .leading, spacing: 16) {
                FieldRow(title: "whisper-cli program") {
                    HStack(spacing: 10) {
                        GField(placeholder: "/opt/homebrew/bin/whisper-cli", text: $settings.whisperPath, mono: true)
                        foundTag(FileManager.default.isExecutableFile(atPath: settings.whisperPath))
                    }
                }
                FieldRow(title: "Model file (ggml)") {
                    HStack(spacing: 10) {
                        GField(placeholder: "ggml-….bin", text: $settings.localModelPath, mono: true)
                        foundTag(FileManager.default.fileExists(atPath: settings.localModelPath))
                        Button("Choose…") {
                            chooseFile(message: "Choose a whisper.cpp model file (ggml-*.bin)", current: settings.localModelPath) {
                                settings.localModelPath = $0
                            }
                        }
                        .buttonStyle(.g(.secondary, height: 40))
                    }
                }
                FieldRow(title: "English-only model file",
                         caption: "Used when Call language is English only. Default is Whisper large-v3, which is strong at English. You can point this at any English-specific whisper.cpp model, such as a .en or distil build.") {
                    HStack(spacing: 10) {
                        GField(placeholder: "ggml-….bin", text: $settings.englishModelPath, mono: true)
                        foundTag(FileManager.default.fileExists(atPath: settings.englishModelPath))
                        Button("Choose…") {
                            chooseFile(message: "Choose an English whisper.cpp model file (ggml-*.bin)", current: settings.englishModelPath) {
                                settings.englishModelPath = $0
                            }
                        }
                        .buttonStyle(.g(.secondary, height: 40))
                    }
                }
            }
            .card(padding: 20)

            VStack(alignment: .leading, spacing: 16) {
                FieldRow(title: "Hinglish model speech mode") {
                    GSegmented(options: ["en", "hi", "auto"], selection: $settings.language,
                               title: { $0 == "en" ? "English mode" : ($0 == "hi" ? "Hindi mode" : "Auto-detect") },
                               label: "Speech mode")
                }
                Text("English mode is best for Hinglish in Roman script.")
                    .font(GFont.ui(12)).foregroundStyle(G.text3).padding(.top, -8)
                FieldRow(title: "Names and terms that may appear", caption: "Optional. Helps spelling.") {
                    GField(placeholder: "Avery, Sam, Platform team", text: $settings.hint)
                }
            }
            .card(padding: 20)
        }
    }
}

private func foundTag(_ ok: Bool) -> some View {
    HStack(spacing: 5) {
        GIcon(ok ? "checkmark" : "exclamationmark.triangle.fill", size: 11, weight: .bold)
        Text(ok ? "Found" : "Not found").font(GFont.ui(12, .semibold))
    }
    .foregroundStyle(ok ? G.success : G.warnIcon)
    .fixedSize()
}

// MARK: - Cloud provider

private struct CloudProviderPage: View {
    let kind: ProviderKind
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState
    @State private var draft = ""
    @State private var replacing = false

    private var key: Binding<String> {
        switch kind {
        case .gemini: return $settings.geminiKey
        case .elevenlabs: return $settings.elevenKey
        default: return $settings.claudeKey
        }
    }

    private var model: Binding<String> {
        switch kind {
        case .gemini: return $settings.geminiModel
        case .elevenlabs: return $settings.elevenModel
        default: return $settings.claudeModel
        }
    }

    private var note: String {
        switch kind {
        case .gemini: return "Audio is uploaded to Google. Enter the exact model name you use, for example your Gemini transcription model."
        case .elevenlabs: return "Audio is uploaded to ElevenLabs. Model name example: scribe_v1 or scribe_v2."
        default: return "Claude cannot listen to audio. It only reads transcripts you already have and returns a reviewed one, so only the text is sent to Anthropic."
        }
    }

    private var keyHint: String {
        switch kind {
        case .gemini: return "Paste the key from Google AI Studio. It goes straight to the Keychain."
        case .elevenlabs: return "Paste the key from your ElevenLabs profile. It goes straight to the Keychain."
        default: return "Paste the key from the Anthropic Console. It goes straight to the Keychain."
        }
    }

    var body: some View {
        let saved = !key.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 12) {
            Breadcrumb(title: providerName(kind))
            HStack(spacing: 12) {
                PageTitle(title: providerName(kind))
                CloudTag(text: kind.hearsAudio ? "Cloud" : "Cloud, text only")
                readinessPill(settings.issue(for: kind))
            }
            WarningBanner(text: cloudNotice(kind))

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("API key").font(GFont.ui(13, .semibold))
                    Text("Stored in your Keychain.").font(GFont.ui(12)).foregroundStyle(G.text3)
                }
                if saved && !replacing {
                    HStack(spacing: 10) {
                        GField(placeholder: "", text: .constant("••••••••••••••••••••••••"), mono: true)
                            .allowsHitTesting(false)
                        Button("Replace key") { replacing = true; draft = "" }.buttonStyle(.g(.secondary, height: 40))
                        Button("Remove key") { key.wrappedValue = ""; ui.toast("Key removed", icon: "trash") }
                            .buttonStyle(.g(.secondary, height: 40))
                    }
                    HStack(spacing: 6) {
                        GIcon("checkmark.circle", size: 12)
                        Text("Saved to Keychain")
                    }
                    .font(GFont.ui(12, .medium)).foregroundStyle(G.success)
                } else {
                    HStack(spacing: 10) {
                        GField(placeholder: "Paste key", text: $draft, secure: true, onSubmit: saveKey)
                        if replacing { Button("Cancel") { replacing = false }.buttonStyle(.g(.secondary, height: 40)) }
                        Button("Save key", action: saveKey).buttonStyle(.g(.primary, height: 40))
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(keyHint).font(GFont.ui(12)).foregroundStyle(G.text3)
                }
            }
            .card(padding: 20)

            VStack(alignment: .leading, spacing: 14) {
                Text("Model").font(GFont.ui(13, .semibold))
                ModelPicker(kind: kind, audioOnly: kind.hearsAudio)
                FieldRow(title: "Model name", caption: note) {
                    GField(placeholder: "Model name", text: model, mono: true)
                }
            }
            .card(padding: 20)
        }
    }

    private func saveKey() {
        let v = draft.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        key.wrappedValue = v
        draft = ""
        replacing = false
        ui.toast("Saved")
    }
}

// MARK: - Output

private struct OutputPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState
    @AppStorage(SpeakerLabelsSetting.key) private var speakerLabels = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                PageTitle(title: "Output")
                Text("How Gemini writes Hindi, and the text “Copy for Claude” puts before a transcript.")
                    .font(GFont.ui(14)).foregroundStyle(G.text2)
            }
            .padding(.bottom, 4)
            FieldRow(title: "Gemini output style") {
                GSegmented(options: OutputStyle.allCases,
                           selection: Binding(get: { settings.style }, set: { settings.style = $0 }),
                           title: { $0.title }, label: "Gemini output style")
                Text(settings.style == .roman ? "Aaj ka update, the build is green." : "आज का अपडेट, the build is green.")
                    .font(GFont.ui(14)).foregroundStyle(G.text2)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.border))
            }
            .card(padding: 20)
            HStack(alignment: .top, spacing: 14) {
                GCheckbox(isOn: $speakerLabels).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speaker labels").font(GFont.ui(13, .semibold))
                    Text("When the audio has more than one speaker, ElevenLabs and compatible Gemini models label each turn as Speaker 1, Speaker 2 and so on. Recordings with a single speaker show no labels. Copy and export keep the labels.")
                        .font(GFont.ui(12)).foregroundStyle(G.text3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                .onTapGesture { speakerLabels.toggle() }
            }
            .card(padding: 20)
            FieldRow(title: "“Copy for Claude” text added before the transcript") {
                TextEditor(text: $settings.template)
                    .font(GFont.ui(14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.borderStrong))
                Button("Reset template") {
                    settings.template = AppSettings.defaultTemplate
                    ui.toast("Template reset")
                }
                .buttonStyle(.g(.secondary, height: 32))
                Text("Saved as you type.").font(GFont.ui(12)).foregroundStyle(G.text3)
            }
            .card(padding: 20)
        }
    }
}

// MARK: - Storage and privacy

private struct StoragePage: View {
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var store: RecordingStore
    @State private var usedBytes: Int64?

    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/Recordings", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                PageTitle(title: "Storage and privacy")
                Text("Each recording is saved automatically, with its transcripts, in its own folder here.")
                    .font(GFont.ui(14)).foregroundStyle(G.text2)
            }
            .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Saved recordings")
                Text(folder.path).font(GFont.mono(13)).textSelection(.enabled)
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.borderStrong))
                HStack(spacing: 10) {
                    Button {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } label: { IconLabel("Show in Finder", "folder") }
                    .buttonStyle(.g(.secondary, height: 36))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(folder.path, forType: .string)
                        ui.toast("Copied")
                    } label: { IconLabel("Copy path", "doc.on.doc") }
                    .buttonStyle(.g(.secondary, height: 36))
                }
                HStack(spacing: 8) {
                    SectionLabel("Disk used")
                    Text(usedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Counting…")
                        .font(GFont.mono(13, .medium))
                    Text("in \(store.recordings.count) recording\(store.recordings.count == 1 ? "" : "s")")
                        .font(GFont.ui(13)).foregroundStyle(G.text2)
                }
                .padding(.top, 4)
            }
            .card(padding: 20)
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("What leaves this Mac")
                leaves("Local (whisper.cpp)", "Nothing sent", "Audio and text stay on this Mac. No internet is needed.", G.success)
                leaves("Google Gemini", "Audio sent", "The recording's audio is uploaded to Google for transcription.", G.warnIcon)
                leaves("ElevenLabs Scribe", "Audio sent", "The recording's audio is uploaded to ElevenLabs for transcription.", G.warnIcon)
                leaves("Claude text review", "Text only", "Only the transcript text goes to Anthropic. Audio is never sent.", G.warnIcon)
            }
            .card(padding: 20)
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Privacy")
                point("lock.shield", "Nothing is uploaded unless you choose a cloud model, and every cloud send asks first.")
                point("key", "API keys live only in the macOS Keychain, never in a file, a log or an export.")
                point("eye.slash", "No accounts, no analytics, no telemetry.")
                point("cloud", "Audio goes only to Gemini or ElevenLabs. Transcript text goes only to Anthropic, for a Claude review.")
            }
            .card(padding: 20)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Danger zone")
                Text("Delete all recordings removes every recording and its transcripts from this Mac. This cannot be undone.")
                    .font(GFont.ui(13)).foregroundStyle(G.text2)
                Button { ui.modal = .deleteAll } label: { IconLabel("Delete all recordings…", "trash") }
                    .buttonStyle(.g(.danger, height: 36)).disabled(store.recordings.isEmpty)
            }
            .card(padding: 20)
        }
        .task { usedBytes = await Self.folderSize(folder) }
    }

    private func leaves(_ name: String, _ tag: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(GFont.ui(13, .semibold))
                Text(text).font(GFont.ui(12)).foregroundStyle(G.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(tag).font(GFont.ui(12, .semibold)).foregroundStyle(color)
        }
    }

    private static func folderSize(_ url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            var total: Int64 = 0
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                while let f = e.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            }
            return total
        }.value
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            GIcon(icon, size: 14).foregroundStyle(G.accentText).frame(width: 18)
            Text(text).font(GFont.ui(14)).foregroundStyle(G.text2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
