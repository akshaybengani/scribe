import SwiftUI
import AppKit

/// Asks the recording detail screen to open its find bar on a query, on a given tab.
struct FindRequest: Equatable {
    let query: String
    let provider: ProviderKind?
}

private enum SearchRow: Identifiable {
    case recording(SearchHit)
    case folder(Folder)
    case transcript(SearchHit)
    var id: String {
        switch self {
        case .recording(let h): return "r-" + h.id
        case .folder(let f): return "f-" + f.id
        case .transcript(let h): return "t-" + h.id
        }
    }
}

/// The global search field in the title bar area, like a browser address bar, and the results panel under it.
/// Cmd+K focuses it. Up and Down move, Return opens the recording at its match, Esc clears and closes.
struct GlobalSearch: View {
    let width: CGFloat
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var search: SearchModel
    @FocusState private var focused: Bool
    @State private var selected = 0

    private var query: String { search.query.trimmingCharacters(in: .whitespaces) }

    private var folderMatches: [Folder] {
        guard !query.isEmpty else { return [] }
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return store.folders.filter {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(q)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .prefix(4).map { $0 }
    }

    /// Recordings first, then folders, then recordings that matched only inside a transcript.
    private var rows: [SearchRow] {
        let hits = search.results
        let named = hits.filter { $0.snippetField != .transcript }.map(SearchRow.recording)
        let inText = hits.filter { $0.snippetField == .transcript }.map(SearchRow.transcript)
        return named + folderMatches.map(SearchRow.folder) + inText
    }

    var body: some View {
        ZStack(alignment: .top) {
            if ui.searchOpen {
                Color.clear.contentShape(Rectangle()).onTapGesture { focused = false }
            }
            VStack(spacing: 6) {
                field
                if ui.searchOpen { panel }
            }
            .frame(width: max(width, 360))
            .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: ui.searchFocusToken) { _, _ in focused = true }
        .onChange(of: focused) { _, now in ui.searchOpen = now }
        .onChange(of: search.query) { _, _ in selected = 0 }
        .onChange(of: search.results) { _, _ in selected = min(selected, max(0, rows.count - 1)) }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 8) {
            GIcon("magnifyingglass", size: 13).foregroundStyle(G.text3)
            TextField("Search recordings, folders and transcripts", text: $search.query)
                .textFieldStyle(.plain).font(GFont.ui(13)).foregroundStyle(G.text)
                .focused($focused).focusEffectDisabled()
                .onSubmit(openSelected)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .accessibilityLabel("Search recordings")
            if search.isSearching || search.isIndexing {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
            }
            if !search.query.isEmpty {
                Button { search.query = ""; focused = true } label: { GIcon("xmark.circle.fill", size: 13).foregroundStyle(G.text3) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            } else {
                Text("⌘K").font(GFont.mono(11)).foregroundStyle(G.text3)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(G.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(G.borderStrong))
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? G.focus : G.borderStrong, lineWidth: focused ? 2 : 1))
        .shadow(color: focused ? G.shadow : .clear, radius: 10, y: 4)
        .help("Search (⌘K)")
    }

    // MARK: Panel

    @ViewBuilder private var panel: some View {
        VStack(spacing: 0) {
            if query.isEmpty {
                hint
            } else if rows.isEmpty && !search.isSearching {
                empty
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            sections
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selected) { _, new in
                        if rows.indices.contains(new) { proxy.scrollTo(rows[new].id, anchor: .center) }
                    }
                }
                footer
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(G.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(G.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: G.shadow, radius: 18, y: 12)
    }

    private var hint: some View {
        VStack(spacing: 6) {
            Text("Search everything on this Mac").font(GFont.ui(14, .semibold))
            Text("Titles, folders and what was said. Use quotes for an exact phrase. Nothing leaves this Mac.")
                .font(GFont.ui(12)).foregroundStyle(G.text2).multilineTextAlignment(.center)
        }
        .padding(18).frame(maxWidth: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            GIcon("magnifyingglass", size: 18).foregroundStyle(G.text3)
            Text("No matches for “\(query)”").font(GFont.ui(14, .semibold))
            Text("Try fewer words, or check the spelling. Search ignores capitals and accents.")
                .font(GFont.ui(12)).foregroundStyle(G.text2).multilineTextAlignment(.center)
        }
        .padding(20).frame(maxWidth: .infinity)
    }

    @ViewBuilder private var sections: some View {
        let all = rows
        let named = all.indices.filter { if case .recording = all[$0] { return true } else { return false } }
        let folders = all.indices.filter { if case .folder = all[$0] { return true } else { return false } }
        let texts = all.indices.filter { if case .transcript = all[$0] { return true } else { return false } }
        if !named.isEmpty { sectionLabel("Recordings"); ForEach(named, id: \.self) { rowView(all[$0], index: $0) } }
        if !folders.isEmpty { sectionLabel("Folders"); ForEach(folders, id: \.self) { rowView(all[$0], index: $0) } }
        if !texts.isEmpty { sectionLabel("In transcripts"); ForEach(texts, id: \.self) { rowView(all[$0], index: $0) } }
    }

    private func sectionLabel(_ t: String) -> some View {
        SectionLabel(t).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    private func rowView(_ row: SearchRow, index: Int) -> some View {
        let on = index == selected
        return Button { selected = index; openSelected() } label: {
            Group {
                switch row {
                case .recording(let h), .transcript(let h): hitRow(h)
                case .folder(let f): folderRow(f)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? G.surface3 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(row.id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func hitRow(_ h: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(highlight(h.title, h.titleRanges)).font(GFont.ui(14, .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if h.matchCount > 0 {
                    Text("\(h.matchCount) \(h.matchCount == 1 ? "match" : "matches")")
                        .font(GFont.mono(11)).foregroundStyle(G.text2)
                }
            }
            HStack(spacing: 6) {
                if let f = folderOf(h) { FolderSwatch(color: f.color.swiftUI) }
                Text(highlight(h.folderPath, h.folderRanges)).lineLimit(1)
                Text("· " + shortDate(h.created))
                if let p = h.provider, h.snippetField == .transcript { Text("· " + p.short) }
            }
            .font(GFont.ui(12)).foregroundStyle(G.text3)
            if h.snippetField == .transcript {
                Text(h.attributedSnippet).font(GFont.ui(12)).foregroundStyle(G.text2).lineLimit(2)
            }
        }
    }

    private func folderRow(_ f: Folder) -> some View {
        HStack(spacing: 10) {
            FolderSwatch(color: f.color.swiftUI, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(GFont.ui(14, .semibold))
                Text(store.path(of: f.id)).font(GFont.ui(12)).foregroundStyle(G.text3)
            }
            Spacer()
            Text("\(store.recordingCount(in: f.id))").font(GFont.mono(12)).foregroundStyle(G.text2)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("\(search.totalMatches) \(search.totalMatches == 1 ? "recording" : "recordings")")
            Spacer()
            hintKey("↑↓", "Move")
            hintKey("↩", "Open")
            hintKey("esc", "Close")
        }
        .font(GFont.ui(11)).foregroundStyle(G.text3)
        .padding(.horizontal, 12).frame(height: 30)
        .background(G.surface2)
        .overlay(alignment: .top) { Rectangle().fill(G.border).frame(height: 1) }
    }

    private func hintKey(_ k: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(k).font(GFont.mono(10))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(G.borderStrong))
            Text(label)
        }
    }

    // MARK: Actions

    private func folderOf(_ h: SearchHit) -> Folder? { store.recordings.first { $0.id == h.recordingID }.flatMap { store.folder($0.folderID) } }

    private func highlight(_ text: String, _ ranges: [Range<String.Index>]) -> AttributedString {
        var a = AttributedString(text)
        for r in ranges {
            guard let ar = Range(r, in: a) else { continue }
            a[ar].foregroundColor = G.accentText
            a[ar].inlinePresentationIntent = .stronglyEmphasized
        }
        return a
    }

    private func move(_ d: Int) {
        let n = rows.count
        guard n > 0 else { return }
        selected = (selected + d + n) % n
    }

    private func close() {
        search.query = ""
        focused = false
    }

    private func openSelected() {
        let all = rows
        guard all.indices.contains(selected) else { return }
        let q = search.query
        switch all[selected] {
        case .folder(let f):
            ui.goLibrary(folder: f.id)
        case .recording(let h), .transcript(let h):
            let folder = store.recordings.first { $0.id == h.recordingID }?.folderID
            ui.open(recording: h.recordingID, folder: folder)
            ui.pendingFind = h.matchCount > 0 && h.snippetField == .transcript ? FindRequest(query: q, provider: h.provider) : nil
        }
        close()
    }
}
