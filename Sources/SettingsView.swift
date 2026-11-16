import SwiftUI
import AppKit

/// One flat page. Every provider shows its own status so a missing key or model is obvious.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Models").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    localSection
                    cloudSection(.gemini, key: $settings.geminiKey, model: $settings.geminiModel,
                                 note: "Audio is uploaded to Google. Enter the exact model name you use, for example your Gemini transcription model.")
                    cloudSection(.elevenlabs, key: $settings.elevenKey, model: $settings.elevenModel,
                                 note: "Audio is uploaded to ElevenLabs. Model name example: scribe_v1 or scribe_v2.")
                    cloudSection(.claude, key: $settings.claudeKey, model: $settings.claudeModel,
                                 note: "Claude cannot listen to audio. It only reads transcripts you already have and returns a reviewed one, so only the text is sent to Anthropic.")
                    outputSection
                    storageSection
                }
                .padding(16)
            }
        }
        .frame(width: 600, height: 680)
    }

    // MARK: Sections

    private func header(_ kind: ProviderKind) -> some View {
        HStack(spacing: 8) {
            Text(kind.title).font(.headline)
            if kind.isCloud { Label("Cloud", systemImage: "cloud").font(.caption).foregroundStyle(.orange) }
            Spacer()
            StatusBadge(issue: settings.issue(for: kind))
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(.local)
            Text("Private: audio never leaves this Mac and no internet is needed.").font(.caption).foregroundStyle(.secondary)
            LabeledField(title: "whisper-cli program", text: $settings.whisperPath)
            HStack(alignment: .bottom) {
                LabeledField(title: "Model file (ggml)", text: $settings.localModelPath)
                Button("Choose…") { chooseModel() }
            }
            HStack(alignment: .bottom) {
                LabeledField(title: "English-only model file (used when Call language is English only)", text: $settings.englishModelPath)
                Button("Choose…") { chooseEnglishModel() }
            }
            Text("Default is Whisper large-v3, which is strong at English. You can point this at any English-specific whisper.cpp model, such as a .en or distil build.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Hinglish model speech mode", selection: $settings.language) {
                Text("English mode (best for Hinglish in Roman script)").tag("en")
                Text("Hindi mode").tag("hi")
                Text("Auto-detect").tag("auto")
            }
            LabeledField(title: "Names and terms that may appear (optional, helps spelling)", text: $settings.hint)
        }
        .sectionBox()
    }

    private func cloudSection(_ kind: ProviderKind, key: Binding<String>, model: Binding<String>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(kind)
            Text(note).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("API key (stored in your Keychain)").font(.caption).foregroundStyle(.secondary)
                SecureField("Paste key", text: key).textFieldStyle(.roundedBorder)
            }
            LabeledField(title: "Model name", text: model)
        }
        .sectionBox()
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output").font(.headline)
            Picker("Gemini output style", selection: Binding(get: { settings.style }, set: { settings.style = $0 })) {
                ForEach(OutputStyle.allCases) { Text($0.title).tag($0) }
            }
            Text("“Copy for Claude” text added before the transcript").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.template)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Button("Reset template") { settings.template = AppSettings.defaultTemplate }
                .buttonStyle(.link)
        }
        .sectionBox()
    }

    private var storageSection: some View {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/Recordings", isDirectory: true)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Saved recordings").font(.headline)
            Text("Each recording is saved automatically, with its transcripts, in its own folder here. Nothing is uploaded unless you choose a cloud model.")
                .font(.caption).foregroundStyle(.secondary)
            Text(folder.path).font(.callout).textSelection(.enabled)
            Button("Show in Finder") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
        .sectionBox()
    }

    private func chooseEnglishModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = AppSettings.modelsFolder
        panel.message = "Choose an English whisper.cpp model file (ggml-*.bin)"
        if panel.runModal() == .OK, let url = panel.url { settings.englishModelPath = url.path }
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = AppSettings.modelsFolder
        panel.message = "Choose a whisper.cpp model file (ggml-*.bin)"
        if panel.runModal() == .OK, let url = panel.url { settings.localModelPath = url.path }
    }
}

struct StatusBadge: View {
    let issue: String?
    var body: some View {
        if let issue {
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).help(issue)
        } else {
            Label("Ready", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        }
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

extension View {
    func sectionBox() -> some View {
        self.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}
