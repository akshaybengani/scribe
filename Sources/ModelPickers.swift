import SwiftUI

/// What a cloud model can do about speaker labels. `ModelInfo` has no field for it, so this reads the model's
/// catalog note and its id: ElevenLabs Scribe models always send diarization, a note that mentions speakers
/// (and optionally "30 min") is honoured, and a Gemini model whose id contains "transcribe" is treated as a
/// diarizing transcription model with a 30 minute limit. Change the rules here if the catalog grows a real field.
@MainActor enum SpeakerSupport {
    struct Info {
        var labels: Bool
        var limitMinutes: Int?
    }

    static func info(_ kind: ProviderKind, model: ModelInfo?, id: String) -> Info {
        let note = (model?.note ?? "").lowercased()
        var labels = note.contains("speaker")
        var limit: Int?
        if labels, let r = note.range(of: #"(\d+)\s*min"#, options: .regularExpression) {
            let digits = note[r].filter(\.isNumber)
            limit = Int(digits)
        }
        if kind == .elevenlabs { labels = true }
        if kind == .gemini, id.lowercased().contains("transcribe") {
            labels = true
            limit = limit ?? 30
        }
        return Info(labels: labels, limitMinutes: limit)
    }

    /// A warning when the chosen model labels speakers only up to a limit and the recording is longer.
    static func longRecordingWarning(_ kind: ProviderKind, settings: AppSettings, seconds: Double?) -> String? {
        guard kind.isCloud, let seconds else { return nil }
        let id = settings.selectedModel(kind)
        let model = settings.modelOptions(kind).first { $0.id == id }
        let info = info(kind, model: model, id: id)
        guard info.labels, let limit = info.limitMinutes, seconds > Double(limit) * 60 else { return nil }
        return "\(model?.displayName ?? id) labels speakers only in the first \(limit) minutes. This recording is \(humanDuration(seconds)) long, so later speech will have no speaker labels."
    }
}

/// Picks the model for one cloud provider from the catalog (curated plus fetched, audio-capable first),
/// with a Refresh models button that shows loading and error state.
struct ModelPicker: View {
    let kind: ProviderKind
    var audioOnly = true
    var recordingSeconds: Double? = nil
    /// Icon-only Refresh button, for narrow columns.
    var compact = false
    @EnvironmentObject var settings: AppSettings

    private var options: [ModelInfo] { audioOnly ? settings.audioModelOptions(kind) : settings.modelOptions(kind) }
    private var selected: ModelInfo? { settings.modelOptions(kind).first { $0.id == settings.selectedModel(kind) } }
    private var state: ModelCatalogState { settings.catalog(kind) }
    private var hasKey: Bool { !settings.apiKey(kind).trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(options) { m in
                        Button {
                            settings.setModel(kind, m.id)
                        } label: {
                            let info = SpeakerSupport.info(kind, model: m, id: m.id)
                            Label(m.displayName + (info.labels ? ", speaker labels" : ""),
                                  systemImage: m.id == settings.selectedModel(kind) ? "checkmark" : "")
                        }
                    }
                } label: {
                    GMenuLabel(content: AnyView(
                        HStack(spacing: 8) {
                            Text(selected?.displayName ?? settings.selectedModel(kind)).lineLimit(1)
                            Spacer(minLength: 0)
                            GIcon("chevron.up.chevron.down", size: 10, weight: .semibold).foregroundStyle(G.text3)
                        }), height: 36)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(kind.short) model")
                Button { Task { await settings.refreshModels(kind) } } label: {
                    if compact { GIcon("arrow.clockwise", size: 13) }
                    else { IconLabel(state.isLoading ? "Refreshing" : "Refresh models", "arrow.clockwise") }
                }
                .buttonStyle(compact ? .g(.secondary, height: 36, square: true) : .g(.secondary, height: 36))
                .accessibilityLabel("Refresh models")
                .disabled(state.isLoading || !hasKey)
                .help(hasKey ? "Ask \(kind.company) for its current model list" : "Add an API key to load the model list")
            }
            chips
            status
            if let w = SpeakerSupport.longRecordingWarning(kind, settings: settings, seconds: recordingSeconds) {
                warning(w)
            }
            if let w = settings.modelWarning(kind) { warning(w) }
        }
    }

    @ViewBuilder private var chips: some View {
        let info = SpeakerSupport.info(kind, model: selected, id: settings.selectedModel(kind))
        if selected != nil || info.labels {
            VStack(alignment: .leading, spacing: 6) {
                if info.labels {
                    Chip(text: info.limitMinutes.map { "Speaker labels, up to \($0) min" } ?? "Speaker labels")
                }
                if let m = selected, !m.note.isEmpty {
                    Text(m.note).font(GFont.ui(12)).foregroundStyle(G.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if state.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the model list from \(kind.company)…").font(GFont.ui(12)).foregroundStyle(G.text2)
            }
        } else if let e = state.error {
            HStack(alignment: .top, spacing: 6) {
                GIcon("exclamationmark.circle.fill", size: 12).foregroundStyle(G.danger).padding(.top, 1)
                Text("Could not refresh the list: \(e) The built-in list is still available.")
                    .font(GFont.ui(12)).foregroundStyle(G.danger).fixedSize(horizontal: false, vertical: true)
            }
        } else if let t = state.lastRefreshed {
            Text("List updated \(t.formatted(.relative(presentation: .named))). \(options.count) models.")
                .font(GFont.ui(12)).foregroundStyle(G.text3)
        } else if !hasKey {
            Text("Built-in list. Add an API key to load every model your account can use.")
                .font(GFont.ui(12)).foregroundStyle(G.text3)
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            GIcon("exclamationmark.triangle.fill", size: 12).foregroundStyle(G.warnIcon).padding(.top, 1)
            Text(text).font(GFont.ui(12)).foregroundStyle(G.warnText).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.warnBorder))
    }
}
