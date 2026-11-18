import SwiftUI
import AppKit

/// Settings as pages: an overview of the four providers, one page per provider, output, and storage.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState

    private enum Top: Hashable { case models, output, appearance, claudeCode, storage }

    private var top: Top {
        switch ui.settingsPage {
        case .models, .local, .cloud: return .models
        case .output: return .output
        case .appearance: return .appearance
        case .claudeCode: return .claudeCode
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
                    navItem("Appearance", "circle.lefthalf.filled", on: top == .appearance) { ui.settingsPage = .appearance }
                    navItem("Claude Code", "terminal", on: top == .claudeCode) { ui.settingsPage = .claudeCode }
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
        case .appearance: AppearancePage()
        case .claudeCode: ClaudeCodePage()
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

// MARK: - Appearance

private struct AppearancePage: View {
    @AppStorage(AppTheme.key) private var theme: AppTheme = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                PageTitle(title: "Appearance")
                Text("Choose light or dark, or let Scribe follow your Mac.")
                    .font(GFont.ui(14)).foregroundStyle(G.text2)
            }
            .padding(.bottom, 4)
            FieldRow(title: "Theme") {
                GSegmented(options: AppTheme.allCases, selection: $theme,
                           title: { $0.title }, icon: { $0.icon }, label: "Theme")
                Text(theme == .system ? "Matches the light or dark setting in System Settings > Appearance."
                     : "Scribe stays \(theme.title.lowercased()) whatever macOS is set to.")
                    .font(GFont.ui(12)).foregroundStyle(G.text3)
            }
            .card(padding: 20)
        }
        .onChange(of: theme) { _, new in new.apply() }
    }
}

// MARK: - Claude Code (MCP)

/// Where Scribe stands in Claude Code. Found by reading ~/.claude.json; Scribe never writes it.
enum MCPRegistration: Equatable {
    case notAdded
    /// Added for every project (user scope).
    case user(command: String)
    /// Added only inside these project folders (local scope).
    case projects([String], command: String)

    static var serverPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/scribe-mcp").path
    }
    static var addCommand: String { "claude mcp add --scope user scribe -- \(serverPath)" }
    static let removeCommand = "claude mcp remove scribe -s user"

    static func read() -> MCPRegistration {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .notAdded }
        func command(_ servers: Any?) -> String? {
            guard let entry = (servers as? [String: Any])?["scribe"] as? [String: Any] else { return nil }
            return entry["command"] as? String ?? ""
        }
        if let c = command(root["mcpServers"]) { return .user(command: c) }
        var found: [String] = []
        var cmd = ""
        for (path, value) in (root["projects"] as? [String: Any]) ?? [:] {
            if let c = command((value as? [String: Any])?["mcpServers"]) { found.append(path); cmd = c }
        }
        return found.isEmpty ? .notAdded : .projects(found.sorted(), command: cmd)
    }
}

private struct ClaudeCodePage: View {
    @EnvironmentObject var ui: UIState
    @State private var reg: MCPRegistration = .notAdded

    private var serverExists: Bool { FileManager.default.isExecutableFile(atPath: MCPRegistration.serverPath) }

    private let tools: [(String, String)] = [
        ("get_latest_call", "Import the most recent call with its full transcript"),
        ("search_calls", "The same global search as ⌘K: titles, folders and every transcript"),
        ("get_call", "Import any call by id, with a chosen transcript or all of them"),
        ("list_recent_calls", "The latest calls with date, length, language and folder"),
        ("list_folders", "The folder tree, and the calls inside a folder"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                PageTitle(title: "Claude Code")
                Text("Scribe includes an MCP server, so Claude Code can find and import your calls on request. It is read-only: Claude can list, search and read calls, never change or delete them.")
                    .font(GFont.ui(14)).foregroundStyle(G.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
            statusCard
            setupCard
            toolsCard
        }
        .onAppear { reg = MCPRegistration.read() }
    }

    private var status: (StatusPill.Kind, String, String) {
        if !serverExists {
            return (.bad, "Server missing", "This copy of Scribe has no scribe-mcp next to it. Rebuild with build.sh.")
        }
        switch reg {
        case .notAdded:
            return (.neutral, "Not added", "Claude Code does not know about Scribe yet. Run the command below once.")
        case .user(let c):
            return c == MCPRegistration.serverPath
                ? (.ready, "Added to Claude Code", "Available in every project. Open a new Claude Code session and run /mcp to see it.")
                : (.warn, "Points elsewhere", "Claude Code runs \(c.isEmpty ? "a different command" : c). Remove it and add it again with the command below.")
        case .projects(let paths, _):
            return (.warn, "Added in \(paths.count) project\(paths.count == 1 ? "" : "s") only",
                    "Only available in: " + paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
                    + ". Run the command below to use it everywhere.")
        }
    }

    private var statusCard: some View {
        let (kind, title, detail) = status
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Status")
                Spacer()
                Button { reg = MCPRegistration.read(); ui.toast("Checked") } label: { IconLabel("Check again", "arrow.clockwise") }
                    .buttonStyle(.g(.secondary, height: 32))
            }
            StatusPill(kind: kind, text: title)
            Text(detail).font(GFont.ui(13)).foregroundStyle(G.text2).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 20)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Add to Claude Code")
            Text("Run this once in Terminal. It makes Scribe available in every Claude Code project.")
                .font(GFont.ui(13)).foregroundStyle(G.text2)
            codeBox(MCPRegistration.addCommand)
            HStack(spacing: 10) {
                copyButton("Copy command", MCPRegistration.addCommand)
                copyButton("Copy remove command", MCPRegistration.removeCommand, icon: "minus.circle")
            }
            SectionLabel("Server").padding(.top, 6)
            codeBox(MCPRegistration.serverPath)
            HStack(spacing: 10) {
                copyButton("Copy path", MCPRegistration.serverPath)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: MCPRegistration.serverPath)])
                } label: { IconLabel("Show in Finder", "folder") }
                .buttonStyle(.g(.secondary, height: 36))
                .disabled(!serverExists)
            }
            Text("Claude reads your library straight from disk, so it works even when Scribe is closed. Transcripts go to Claude only when you ask it for a call.")
                .font(GFont.ui(12)).foregroundStyle(G.text3).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 20)
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("What Claude can do")
            ForEach(tools, id: \.0) { t in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(t.0).font(GFont.mono(12, .medium)).frame(width: 150, alignment: .leading)
                    Text(t.1).font(GFont.ui(13)).foregroundStyle(G.text2)
                }
            }
            Text("Try asking: “Import my latest Scribe call”, or “Search my calls for \"design portal\"”.")
                .font(GFont.ui(12)).foregroundStyle(G.text3).padding(.top, 4)
        }
        .card(padding: 20)
    }

    private func codeBox(_ text: String) -> some View {
        Text(text).font(GFont.mono(12)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.borderStrong))
    }

    private func copyButton(_ title: String, _ value: String, icon: String = "doc.on.doc") -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            ui.toast("Copied")
        } label: { IconLabel(title, icon) }
        .buttonStyle(.g(.secondary, height: 36))
    }
}

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

/// Light, dark, or follow macOS. Stored in UserDefaults under `key` and applied app-wide via `NSApp.appearance`;
/// every Graphite colour is dynamic, so switching needs no other work.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appTheme"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    static var current: AppTheme { AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
