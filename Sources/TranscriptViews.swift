import SwiftUI
import AppKit

// MARK: - Parsing a transcript for display

/// One displayed line of a transcript. Speaker turns look like "Speaker 2: text"; everything else is a plain paragraph.
struct TranscriptLineItem: Identifiable, Equatable {
    let id: Int
    let speaker: Int?
    let body: String
    /// The "[The model hit its output limit ...]" notice Gemini appends when its answer was cut off.
    let isTruncationNotice: Bool
}

/// The lines of one transcript plus every find-bar match in them. Only recordings whose text really has two
/// or more speakers get speaker blocks; with no speaker data nothing extra is shown.
struct TranscriptDoc {
    let lines: [TranscriptLineItem]
    let hasSpeakers: Bool
    let speakerCount: Int
    /// Flat list of matches in reading order: which line and where in that line's body.
    let matches: [(line: Int, range: Range<String.Index>)]
    let truncated: Bool

    init(text: String, query: String = "") {
        var items: [TranscriptLineItem] = []
        var speakers = Set<Int>()
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[The model hit its output limit") {
                items.append(TranscriptLineItem(id: i, speaker: nil, body: line, isTruncationNotice: true))
                continue
            }
            if let (n, rest) = Self.speakerTurn(line) {
                speakers.insert(n)
                items.append(TranscriptLineItem(id: i, speaker: n, body: rest, isTruncationNotice: false))
            } else {
                items.append(TranscriptLineItem(id: i, speaker: nil, body: line, isTruncationNotice: false))
            }
        }
        hasSpeakers = speakers.count >= 2
        speakerCount = speakers.count
        // Without real speaker data keep the lines exactly as written ("Speaker 1: ..." from a single-speaker
        // answer stays part of the text).
        if hasSpeakers {
            lines = items
        } else {
            lines = items.map { it in
                guard let s = it.speaker else { return it }
                return TranscriptLineItem(id: it.id, speaker: nil, body: "Speaker \(s): " + it.body, isTruncationNotice: false)
            }
        }
        truncated = items.contains { $0.isTruncationNotice }
        var found: [(Int, Range<String.Index>)] = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            for (idx, l) in lines.enumerated() where !l.isTruncationNotice {
                for r in findInTranscript(l.body, query: q) { found.append((idx, r)) }
            }
        }
        matches = found.map { (line: $0.0, range: $0.1) }
    }

    /// "Speaker 3: hello" -> (3, "hello").
    static func speakerTurn(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("Speaker ") else { return nil }
        let rest = line.dropFirst("Speaker ".count)
        guard let colon = rest.firstIndex(of: ":"), rest.distance(from: rest.startIndex, to: colon) <= 3,
              let n = Int(rest[rest.startIndex..<colon]) else { return nil }
        return (n, rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
}

/// Colours for speaker blocks. They are the folder colours, so they already work in light and dark,
/// and the same speaker number always gets the same colour.
enum SpeakerPalette {
    static let colors: [Color] = [G.folderBlue, G.folderOrange, G.folderGreen, G.folderPurple,
                                  G.folderPink, G.folderTeal, G.folderYellow, G.folderRed]
    static func color(_ speaker: Int) -> Color { colors[(max(1, speaker) - 1) % colors.count] }
}

// MARK: - Transcript body

struct TranscriptBody: View {
    let doc: TranscriptDoc
    var fontSize: CGFloat = 14
    var reading = false
    /// Index into `doc.matches` that is the current find result, or nil.
    var current: Int? = nil

    private func attributed(_ line: TranscriptLineItem, index: Int) -> AttributedString {
        var a = AttributedString(line.body)
        for (n, m) in doc.matches.enumerated() where m.line == index {
            guard let r = Range(m.range, in: a) else { continue }
            if n == current {
                a[r].backgroundColor = G.accent
                a[r].foregroundColor = G.onAccent
            } else {
                a[r].backgroundColor = G.accent.opacity(0.32)
            }
        }
        return a
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: reading ? 20 : 14) {
                    if doc.hasSpeakers { speakerLegend }
                    ForEach(Array(doc.lines.enumerated()), id: \.element.id) { index, line in
                        row(line, index: index).id(line.id)
                    }
                }
                .frame(maxWidth: reading ? 680 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: reading ? .center : .leading)
                .padding(.horizontal, 28).padding(.vertical, 22)
            }
            .onChange(of: current) { _, new in
                guard let new, doc.matches.indices.contains(new) else { return }
                let id = doc.lines[doc.matches[new].line].id
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let current, doc.matches.indices.contains(current) {
                    let id = doc.lines[doc.matches[current].line].id
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder private func row(_ line: TranscriptLineItem, index: Int) -> some View {
        if line.isTruncationNotice {
            HStack(alignment: .top, spacing: 10) {
                GIcon("exclamationmark.triangle.fill", size: 13).foregroundStyle(G.warnIcon).padding(.top, 2)
                Text(line.body.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                    .font(GFont.ui(13)).foregroundStyle(G.warnText)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.warnBg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.warnBorder))
        } else if let s = line.speaker {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Speaker \(s)")
                    .font(GFont.ui(12, .semibold)).foregroundStyle(SpeakerPalette.color(s))
                    .frame(width: 78, alignment: .leading)
                Text(attributed(line, index: index))
                    .font(GFont.ui(fontSize)).lineSpacing(reading ? 8 : 6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(SpeakerPalette.color(s)).frame(width: 3)
            }
        } else {
            Text(attributed(line, index: index))
                .font(GFont.ui(fontSize)).lineSpacing(reading ? 8 : 6).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var speakerLegend: some View {
        HStack(spacing: 14) {
            ForEach(1...max(1, doc.speakerCount), id: \.self) { n in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(SpeakerPalette.color(n)).frame(width: 8, height: 8)
                    Text("Speaker \(n)").font(GFont.ui(12)).foregroundStyle(G.text2)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Find bar

struct FindBar: View {
    @Binding var query: String
    let count: Int
    @Binding var current: Int
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            GIcon("magnifyingglass", size: 12).foregroundStyle(G.text3)
            TextField("Find in this transcript", text: $query)
                .textFieldStyle(.plain).font(GFont.ui(13)).focused($focused).focusEffectDisabled()
                .onSubmit { step(1) }
            Text(count == 0 ? (query.isEmpty ? "" : "No matches") : "\(current + 1) of \(count)")
                .font(GFont.mono(12)).foregroundStyle(G.text2)
            Button { step(-1) } label: { GIcon("chevron.up", size: 11, weight: .bold) }
                .buttonStyle(.g(.secondary, height: 26, square: true)).disabled(count == 0)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match (⇧⌘G)").accessibilityLabel("Previous match")
            Button { step(1) } label: { GIcon("chevron.down", size: 11, weight: .bold) }
                .buttonStyle(.g(.secondary, height: 26, square: true)).disabled(count == 0)
                .keyboardShortcut("g", modifiers: [.command])
                .help("Next match (⌘G)").accessibilityLabel("Next match")
            Button(action: onClose) { GIcon("xmark", size: 11, weight: .bold) }
                .buttonStyle(.g(.quiet, height: 26, square: true))
                .help("Close (Esc)").accessibilityLabel("Close find bar")
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(G.surface2)
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
        .onChange(of: query) { _, _ in current = 0 }
    }

    private func step(_ d: Int) {
        guard count > 0 else { return }
        current = (current + d + count) % count
    }
}

// MARK: - Progress while transcribing

/// Shown in place of a transcript while one engine works on a recording. Reads the live numbers from
/// `JobRunner.progress`: one bar, mono numbers, elapsed time, the estimate when there is one, and the chunk
/// and upload state for cloud jobs. It never shows a spinner; the elapsed clock and the bar are the signs of life.
struct TranscribingView: View {
    let recording: Recording
    let provider: ProviderKind
    /// Lets a preview or a test show fixed numbers; normally nil and the live job is read.
    var override: JobProgress? = nil
    @EnvironmentObject var jobs: JobRunner
    @EnvironmentObject var settings: AppSettings

    private var p: JobProgress? { override ?? jobs.progress(recording.id, provider) }

    var body: some View {
        let p = self.p
        VStack(spacing: 18) {
            GIcon(provider.isCloud ? "cloud" : "cpu", size: 22)
                .foregroundStyle(G.accentText)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(G.accentSoft))
            VStack(spacing: 6) {
                Text(provider.isCloud ? "Transcribing with \(provider.company)" : "Transcribing on this Mac")
                    .font(GFont.ui(16, .semibold))
                Text(stageLine(p)).font(GFont.ui(14)).foregroundStyle(G.text2)
            }
            VStack(spacing: 10) {
                bar(p).frame(width: 420, height: 6)
                HStack {
                    Text(percentText(p)).font(GFont.mono(13, .medium))
                    Spacer()
                    if let left = p?.remainingText {
                        Text("about \(left) left").font(GFont.mono(12)).foregroundStyle(G.text2)
                    } else {
                        Text("estimating time left").font(GFont.ui(12)).foregroundStyle(G.text3)
                    }
                }
                .frame(width: 420)
            }
            HStack(spacing: 18) {
                stat("Elapsed", p?.elapsedText ?? "0:00")
                if let part = p?.partText { stat("Chunk", part.replacingOccurrences(of: "Part ", with: "")) }
                if let audio = p?.audioText { stat("Audio", audio) }
                if let speed = p?.speedText { stat("Speed", speed) }
            }
            Text(settings.name(provider, language: recording.callLanguage))
                .font(GFont.mono(12)).foregroundStyle(G.text3)
            HStack(spacing: 8) {
                GIcon(provider.isCloud ? "cloud" : "lock.shield", size: 12)
                    .foregroundStyle(provider.isCloud ? G.warnIcon : G.success)
                Text(provider.isCloud
                     ? (provider.hearsAudio ? "Audio is being sent to \(provider.company), a third-party platform."
                                            : "Transcript text is being sent to \(provider.company).")
                     : "Nothing is sent anywhere. You can keep playing the audio meanwhile.")
                    .font(GFont.ui(12)).foregroundStyle(G.text3)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcribing, \(percentText(p)), elapsed \(p?.elapsedText ?? "0:00")")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func stageLine(_ p: JobProgress?) -> String {
        guard let p else { return "Starting…" }
        if p.stage == .uploading, let bytes = p.bytesText { return "Uploading, \(bytes)" }
        if let part = p.partText, p.isChunked { return "\(p.stageName), \(part.lowercased())" }
        return p.stageName + (p.stage == .waiting ? ". Long recordings can take many minutes." : "")
    }

    private func percentText(_ p: JobProgress?) -> String {
        if let f = p?.fraction { return String(format: "%d%%", Int((min(1, max(0, f)) * 100).rounded(.down))) }
        if let f = p?.stageFraction { return String(format: "%d%%", Int((min(1, max(0, f)) * 100).rounded(.down))) }
        return "Working"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(GFont.mono(14, .medium))
            Text(label.uppercased()).font(GFont.ui(10, .semibold)).tracking(0.6).foregroundStyle(G.text3)
        }
    }

    @ViewBuilder private func bar(_ p: JobProgress?) -> some View {
        if let f = p?.fraction ?? p?.stageFraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(G.surface3)
                    Capsule().fill(G.accent).frame(width: max(6, geo.size.width * min(1, max(0, f))))
                }
            }
        } else {
            // Unknown remaining time: a segment sweeps along the track so a long wait is visibly alive.
            TimelineView(.animation) { ctx in
                GeometryReader { geo in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    let w = geo.size.width * 0.3
                    ZStack(alignment: .leading) {
                        Capsule().fill(G.surface3)
                        Capsule().fill(G.accent).frame(width: w).offset(x: -w + (geo.size.width + w) * t)
                    }
                    .clipShape(Capsule())
                }
            }
        }
    }
}

/// A slim one-line progress for a table row or a tab: "42% · 4:07 left".
struct MiniProgress: View {
    let progress: JobProgress?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line).font(GFont.mono(11)).foregroundStyle(G.accentText).lineLimit(1)
            ZStack(alignment: .leading) {
                Capsule().fill(G.surface3)
                if let f = progress?.fraction ?? progress?.stageFraction {
                    GeometryReader { geo in Capsule().fill(G.accent).frame(width: max(3, geo.size.width * f)) }
                }
            }
            .frame(height: 3)
        }
    }

    private var line: String {
        guard let p = progress else { return "Starting" }
        if let f = p.fraction ?? p.stageFraction {
            return "\(Int(f * 100))%" + (p.remainingText.map { " · \($0) left" } ?? " · " + p.elapsedText)
        }
        return p.stageName + " · " + p.elapsedText
    }
}

// MARK: - Job errors with a way forward

enum JobErrorKind {
    case keyRejected, noKey, whisperMissing, modelMissing, offline, failed

    static func classify(_ message: String) -> JobErrorKind {
        let m = message.lowercased()
        if m.contains("whisper-cli was not found") { return .whisperMissing }
        if m.contains("model file is missing") { return .modelMissing }
        if m.contains("no ") && m.contains("api key yet") { return .noKey }
        if m.contains("401") || m.contains("403") || m.contains("api key not valid") || m.contains("invalid api key")
            || m.contains("invalid x-api-key") || m.contains("unauthorized") { return .keyRejected }
        if m.contains("offline") || m.contains("not connected to the internet") || m.contains("network connection was lost")
            || m.contains("could not connect") { return .offline }
        return .failed
    }
}

struct JobErrorPanel: View {
    let kind: ProviderKind
    let message: String
    let recording: Recording
    let onRetry: () -> Void
    let onDismiss: () -> Void
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState

    private var jobKind: JobErrorKind { JobErrorKind.classify(message) }
    private var isWarning: Bool { [.noKey, .whisperMissing, .modelMissing, .offline].contains(jobKind) }
    private var accent: Color { isWarning ? G.warnIcon : G.danger }

    private var title: String {
        switch jobKind {
        case .keyRejected: return "\(kind.short) rejected the API key"
        case .noKey: return "\(kind.short) needs an API key"
        case .whisperMissing: return "whisper-cli was not found"
        case .modelMissing: return "The local model file is missing"
        case .offline: return "You are offline"
        case .failed: return kind == .local ? "Transcription failed" : "\(kind.short) could not finish this transcript"
        }
    }

    private var lead: String {
        switch jobKind {
        case .keyRejected:
            return "\(kind.company) did not accept the key, so this recording was not transcribed. The recording is saved and nothing was lost. Replace the key in AI Models, then retry."
        case .noKey:
            return "Add a key in AI Models, then retry. The recording is saved."
        case .whisperMissing:
            return "Local transcription needs the whisper-cli program. The recording is saved. Install it with Homebrew, then retry."
        case .modelMissing:
            return "Scribe looked for the model file and it is not there. The recording is saved. Choose a whisper.cpp model file (ggml-*.bin), then retry."
        case .offline:
            return "\(kind.title) needs an internet connection. The recording is saved. The local model runs on this Mac with no connection."
        case .failed:
            return "The provider failed before it returned any text. The audio is saved and nothing was lost. Earlier transcripts are unchanged."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                GIcon(isWarning ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill", size: 16).foregroundStyle(accent).padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(GFont.ui(15, .semibold)).foregroundStyle(G.text)
                    Text(lead).font(GFont.ui(13)).foregroundStyle(G.text2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            detail
            HStack(spacing: 8) {
                Button(action: onRetry) { IconLabel("Retry", "arrow.clockwise") }.buttonStyle(.g(.primary, height: 32))
                switch jobKind {
                case .keyRejected, .noKey:
                    Button("Fix in AI Models") { ui.openSettings(.cloud(kind)) }.buttonStyle(.g(.secondary, height: 32))
                case .whisperMissing:
                    Button("Open AI Models") { ui.openSettings(.local) }.buttonStyle(.g(.secondary, height: 32))
                case .modelMissing:
                    Button("Choose model file") { ui.openSettings(.local) }.buttonStyle(.g(.secondary, height: 32))
                case .offline:
                    Button("Switch to local") { settings.primary = .local; ui.toast("Local model selected", icon: "cpu") }
                        .buttonStyle(.g(.secondary, height: 32))
                case .failed:
                    if settings.issue(for: kind, language: recording.callLanguage) != nil {
                        Button("AI Models") { ui.openSettings(kind == .local ? .local : .cloud(kind)) }.buttonStyle(.g(.secondary, height: 32))
                    }
                }
                Button(jobKind == .failed ? "Keep the recording" : "Dismiss", action: onDismiss).buttonStyle(.g(.quiet, height: 32))
                Spacer()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isWarning ? G.warnBg : G.dangerSoft))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isWarning ? G.warnBorder : G.danger))
        .padding(.horizontal, 14)
    }

    @ViewBuilder private var detail: some View {
        switch jobKind {
        case .whisperMissing:
            VStack(alignment: .leading, spacing: 8) {
                Text("Expected at \(settings.whisperPath)").font(GFont.mono(12)).foregroundStyle(G.text2).textSelection(.enabled)
                HStack(spacing: 10) {
                    Text("$").font(GFont.mono(13)).foregroundStyle(G.text3)
                    Text("brew install whisper-cpp").font(GFont.mono(13)).textSelection(.enabled)
                    Spacer()
                    Button { copyText("brew install whisper-cpp") } label: { IconLabel("Copy", "doc.on.doc") }
                        .buttonStyle(.g(.secondary, height: 26))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.border))
            }
        case .modelMissing:
            Text("Expected at \(settings.config().localPath(recording.callLanguage))")
                .font(GFont.mono(12)).foregroundStyle(G.text2).textSelection(.enabled)
        default:
            Text(message).font(GFont.mono(12)).foregroundStyle(G.text2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg.opacity(0.6)))
        }
    }

    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        ui.toast("Copied")
    }
}
