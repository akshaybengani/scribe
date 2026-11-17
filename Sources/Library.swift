import SwiftUI
import AppKit

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var recorder: Recorder
    @State private var dropTarget: String?     // folder id, or "" for the top level

    private struct TreeEntry: Identifiable {
        let folder: Folder
        let depth: Int
        let hasChildren: Bool
        var id: String { folder.id }
    }

    private func entries(parent: String? = nil, depth: Int = 0) -> [TreeEntry] {
        store.children(of: parent).flatMap { f -> [TreeEntry] in
            let hasKids = !store.children(of: f.id).isEmpty
            let me = TreeEntry(folder: f, depth: depth, hasChildren: hasKids)
            return [me] + (ui.collapsed.contains(f.id) ? [] : entries(parent: f.id, depth: depth + 1))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LogoMark()
                Text("Scribe").font(GFont.ui(15, .semibold)).tracking(-0.15)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            searchField
            VStack(spacing: 2) {
                navItem("Record", "mic", on: ui.section == .record, help: "New recording (⌘N)") { ui.goRecord() }
                navItem("Library", "folder", on: ui.section == .library) { ui.goLibrary(folder: ui.folder) }
                navItem("Import audio", "square.and.arrow.down", on: ui.section == .importAudio) { ui.section = .importAudio }
                navItem("Settings", "gearshape", on: ui.section == .settings || ui.section == .setup, help: "Settings (⌘,)") { ui.openSettings() }
            }
            HStack {
                SectionLabel("Folders")
                Spacer()
                Button { ui.modal = .newFolder(parent: ui.folder) } label: {
                    GIcon("plus", size: 11, weight: .bold).foregroundStyle(G.text2)
                        .frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(G.borderStrong))
                }
                .buttonStyle(.plain)
                .help(ui.folder == nil ? "New folder (⇧⌘N)" : "New folder inside \(store.path(of: ui.folder)) (⇧⌘N)")
                .accessibilityLabel("New folder")
            }
            .padding(.horizontal, 8).padding(.top, 2)
            tree
            statusCard
        }
        .padding(.top, 36).padding(.horizontal, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(G.sidebar)
    }

    // MARK: Pieces

    private var searchField: some View {
        Button { ui.focusSearch() } label: {
            HStack(spacing: 8) {
                GIcon("magnifyingglass", size: 12)
                Text("Search recordings").font(GFont.ui(13))
                Spacer()
                Text("⌘K").font(GFont.mono(11)).foregroundStyle(G.text3)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(G.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(G.borderStrong))
            }
            .foregroundStyle(G.text3)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search recordings (⌘K)")
    }

    private func navItem(_ title: String, _ icon: String, on: Bool, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                GIcon(icon, size: 14).frame(width: 18)
                Text(title).font(GFont.ui(14, .medium))
                Spacer()
                if title == "Record" && recorder.isRecording {
                    HStack(spacing: 5) {
                        Circle().fill(recorder.isPaused ? G.bar : G.accent).frame(width: 6, height: 6)
                        Text(formatTime(recorder.elapsed)).font(GFont.mono(11)).foregroundStyle(G.text2)
                    }
                }
            }
            .foregroundStyle(on ? G.text : G.text2)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? G.surface3 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var tree: some View {
        ScrollView {
            VStack(spacing: 1) {
                TreeRow(icon: "line.3.horizontal", title: "All recordings", count: store.recordings.count,
                        selected: ui.section == .library && ui.folder == nil, dropTarget: dropTarget == "")
                    .onTapGesture { ui.goLibrary(folder: nil) }
                    .dropDestination(for: String.self, action: { items, _ in drop(items, onto: nil) },
                                     isTargeted: { dropTarget = $0 ? "" : (dropTarget == "" ? nil : dropTarget) })
                ForEach(entries()) { e in folderRow(e) }
                if store.folders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No folders yet. Create one to sort recordings, and nest folders as deep as you like.")
                            .font(GFont.ui(13)).foregroundStyle(G.text3).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { ui.modal = .newFolder(parent: nil) } label: { IconLabel("New folder", "plus") }
                            .buttonStyle(.g(.secondary))
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                }
                // Empty area below the tree is the drop target for the top level.
                Color.clear.frame(height: 40)
                    .dropDestination(for: String.self, action: { items, _ in drop(items, onto: nil) })
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Folders")
    }

    private func folderRow(_ e: TreeEntry) -> some View {
        let f = e.folder
        return TreeRow(depth: e.depth,
                       chevron: e.hasChildren ? !ui.collapsed.contains(f.id) : nil,
                       onToggle: {
                           if ui.collapsed.contains(f.id) { ui.collapsed.remove(f.id) } else { ui.collapsed.insert(f.id) }
                       },
                       swatch: f.color.swiftUI, title: f.name, count: store.recordingCount(in: f.id),
                       selected: ui.section == .library && ui.folder == f.id,
                       dropTarget: dropTarget == f.id)
            .onTapGesture { ui.goLibrary(folder: f.id) }
            .draggable("f:" + f.id)
            .dropDestination(for: String.self, action: { items, _ in drop(items, onto: f.id) },
                             isTargeted: { dropTarget = $0 ? f.id : (dropTarget == f.id ? nil : dropTarget) })
            .contextMenu { folderMenu(f) }
    }

    @ViewBuilder
    private func folderMenu(_ f: Folder) -> some View {
        Button("New folder inside") { ui.modal = .newFolder(parent: f.id) }
        Button("Rename or recolor…") { ui.modal = .editFolder(f) }
        Menu("Move to") {
            Button("Library (top level)") { moveFolder(f, to: nil) }.disabled(f.parentID == nil)
            Divider()
            ForEach(store.flatFolders(excluding: store.descendantIDs(of: f.id)), id: \.folder.id) { item in
                Button(item.path) { moveFolder(f, to: item.folder.id) }.disabled(f.parentID == item.folder.id)
            }
        }
        Divider()
        Button("Delete folder…", role: .destructive) { ui.modal = .deleteFolder(f) }
    }

    private func moveFolder(_ f: Folder, to parent: String?) {
        if store.moveFolder(f.id, to: parent) { toastMoved(to: parent) }
    }

    private var statusCard: some View {
        let issue = settings.issue(for: settings.primary)
        let model = settings.config().model(.local, settings.callLanguage)
        let title: String, body: String, icon: String, color: Color
        if let issue {
            title = settings.primary == .local ? "Setup not finished" : "\(settings.primary.short) needs attention"
            body = issue; icon = "exclamationmark.triangle.fill"; color = G.warnIcon
        } else if settings.primary == .local {
            title = "Local model ready"; body = "\(model), on this Mac"; icon = "checkmark.circle"; color = G.success
        } else {
            title = "\(settings.primary.short) ready"
            body = "Audio is sent to \(settings.primary.company) when you transcribe."
            icon = "cloud"; color = G.success
        }
        return Button {
            if issue != nil, settings.primary == .local { ui.section = .setup }
            else if issue != nil { ui.openSettings(.cloud(settings.primary)) }
            else { ui.openSettings(settings.primary == .local ? .local : .cloud(settings.primary)) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                GIcon(icon, size: 14).foregroundStyle(color).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(GFont.ui(13, .semibold)).foregroundStyle(G.text)
                    Text(body).font(GFont.ui(12)).foregroundStyle(G.text3).lineSpacing(2).lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
        }
        .buttonStyle(.plain)
        .help(issue ?? "Open model settings")
    }

    // MARK: Drag and drop

    /// Drag a recording or folder onto a folder (or the empty list area for the top level).
    private func drop(_ items: [String], onto target: String?) -> Bool {
        var moved = false
        for item in items {
            if item.hasPrefix("r:") {
                store.setFolder(String(item.dropFirst(2)), target)
                moved = true
            } else if item.hasPrefix("f:") {
                moved = store.moveFolder(String(item.dropFirst(2)), to: target) || moved
            }
        }
        if moved { toastMoved(to: target) }
        return moved
    }

    private func toastMoved(to target: String?) {
        let f = store.folder(target)
        ui.toast("Moved to \(f?.name ?? "Library")", icon: f == nil ? "tray.full" : nil, swatch: f?.color.swiftUI)
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var jobs: JobRunner
    @State private var anchor: String?

    private var folder: Folder? { store.folder(ui.folder) }
    private var rows: [Recording] { ui.folder == nil ? store.recordings : store.recordings(in: ui.folder) }
    private var subfolders: [Folder] { store.children(of: ui.folder) }

    /// Library > Daily standups > Platform team
    private var crumbs: [Folder] {
        var chain: [Folder] = []
        var cur = folder
        var steps = 0
        while let f = cur, steps < 50 { chain.insert(f, at: 0); cur = store.folder(f.parentID); steps += 1 }
        return chain
    }

    private func total(_ list: [Recording]) -> Double { list.reduce(0) { $0 + $1.duration } }

    private var caption: String {
        if store.recordings.isEmpty { return "No recordings yet" }
        let n = rows.count
        if n == 0 { return "0 recordings" }
        return "\(n) recording\(n == 1 ? "" : "s"), \(humanDuration(total(rows))) in total"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if ui.selectionMode { selectionBar }
                if !subfolders.isEmpty { overview }
                if !rows.isEmpty { table }
                if rows.isEmpty && subfolders.isEmpty { emptyState }
            }
            .padding(.top, 20).padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button { ui.goLibrary(folder: nil) } label: {
                        Text("Library").foregroundStyle(folder == nil ? G.text : G.text3)
                    }
                    .buttonStyle(.plain)
                    ForEach(crumbs) { c in
                        GIcon("chevron.right", size: 9, weight: .bold).foregroundStyle(G.text3)
                        Button { ui.goLibrary(folder: c.id) } label: {
                            HStack(spacing: 6) {
                                FolderSwatch(color: c.color.swiftUI)
                                Text(c.name).foregroundStyle(c.id == folder?.id ? G.text : G.text3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(GFont.ui(12, .medium))
                .frame(height: 18)
                HStack(spacing: 10) {
                    if let f = folder { FolderSwatch(color: f.color.swiftUI, size: 12) }
                    Text(folder?.name ?? "Library").font(GFont.ui(20, .semibold)).tracking(-0.4).lineLimit(1)
                    if let f = folder {
                        Button { ui.modal = .editFolder(f) } label: {
                            IconLabel(f.color.label, "pencil")
                        }
                        .buttonStyle(.g(.secondary, height: 28))
                        .help("Rename or recolor folder")
                        .accessibilityLabel("Rename or recolor folder")
                    }
                }
                .frame(height: 28)
                Text(caption).font(GFont.ui(13)).foregroundStyle(G.text2).frame(height: 18)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button { ui.modal = .newFolder(parent: ui.folder) } label: {
                    IconLabel(folder == nil ? "New folder" : "New subfolder", "folder.badge.plus")
                }
                .buttonStyle(.g(.secondary))
                .help("New folder (⇧⌘N)")
                if !rows.isEmpty {
                    Button { if ui.selectionMode { ui.endSelection() } else { ui.selectionMode = true } } label: {
                        IconLabel(ui.selectionMode ? "Cancel select" : "Select", "checkmark.circle")
                    }
                    .buttonStyle(.g(.secondary))
                    .help("Select recordings to export (or Command-click rows)")
                }
                if !(rows.isEmpty && subfolders.isEmpty) {
                    Button { ui.section = .importAudio } label: { IconLabel("Import audio", "square.and.arrow.down") }
                        .buttonStyle(.g(.secondary))
                    Button { ui.goRecord() } label: { IconLabel("New recording", "mic") }
                        .buttonStyle(.g(.primary))
                        .help("New recording (⌘N)")
                }
            }
        }
        .frame(minHeight: 76, alignment: .bottom)
    }

    // MARK: Folder overview

    private var overview: some View {
        let all = folder.map { f in store.recordings.filter { r in r.folderID.map(store.descendantIDs(of: f.id).contains) ?? false } }
            ?? store.recordings
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                stat("Recordings, all levels", "\(all.count)")
                stat("Total time", humanDuration(total(all)))
                stat("Subfolders", "\(subfolders.count)")
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(folder == nil ? "Folders" : "Subfolders")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                    ForEach(subfolders) { f in subfolderCard(f) }
                }
            }
            if !rows.isEmpty && folder != nil { SectionLabel("Recordings in this folder") }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            Text(value).font(GFont.mono(24, .medium)).tracking(-0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }

    private func subfolderCard(_ f: Folder) -> some View {
        let ids = store.descendantIDs(of: f.id)
        let recs = store.recordings.filter { r in r.folderID.map(ids.contains) ?? false }
        return Button { ui.goLibrary(folder: f.id) } label: {
            HStack(spacing: 12) {
                FolderSwatch(color: f.color.swiftUI, size: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name).font(GFont.ui(14, .semibold)).lineLimit(1)
                    Text(recs.isEmpty ? "Empty" : humanDuration(total(recs))).font(GFont.ui(12)).foregroundStyle(G.text3)
                }
                Spacer(minLength: 4)
                Text("\(recs.count)").font(GFont.mono(12)).foregroundStyle(G.text2)
            }
            .foregroundStyle(G.text)
            .padding(.horizontal, 16)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(G.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(G.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            var moved = false
            for item in items {
                if item.hasPrefix("r:") { store.setFolder(String(item.dropFirst(2)), f.id); moved = true }
                else if item.hasPrefix("f:") { moved = store.moveFolder(String(item.dropFirst(2)), to: f.id) || moved }
            }
            if moved { ui.toast("Moved to \(f.name)", icon: nil, swatch: f.color.swiftUI) }
            return moved
        }
    }

    // MARK: Recordings table

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if ui.selectionMode {
                    GCheckbox(isOn: Binding(get: { !rows.isEmpty && rows.allSatisfy { ui.selectedIDs.contains($0.id) } },
                                            set: { on in ui.selectedIDs = on ? Set(rows.map(\.id)) : [] }))
                        .frame(width: 20)
                }
                SectionLabel("Title").frame(maxWidth: .infinity, alignment: .leading)
                SectionLabel("Date").frame(width: 112, alignment: .leading)
                SectionLabel("Length").frame(width: 72, alignment: .leading)
                SectionLabel("Transcripts").frame(width: 128, alignment: .leading)
                SectionLabel("Language").frame(width: 132, alignment: .leading)
            }
            .padding(.horizontal, 16).frame(height: 36)
            .background(G.surface2)
            ForEach(rows) { r in row(r) }
        }
        .clippedCard()
    }

    /// The first running job of a recording, if any.
    private func running(_ r: Recording) -> JobProgress? {
        for k in ProviderKind.allCases where jobs.isRunning(r.id, k) { return jobs.progress(r.id, k) ?? JobProgress() }
        return nil
    }

    private func row(_ r: Recording) -> some View {
        let selected = ui.selectedIDs.contains(r.id)
        return HStack(spacing: 12) {
            if ui.selectionMode {
                GCheckbox(isOn: Binding(get: { ui.selectedIDs.contains(r.id) },
                                        set: { on in if on { ui.selectedIDs.insert(r.id) } else { ui.selectedIDs.remove(r.id) } }))
                    .frame(width: 20)
            }
            HStack(spacing: 8) {
                if ui.folder == nil, let f = store.folder(r.folderID) { FolderSwatch(color: f.color.swiftUI) }
                Text(r.title).font(GFont.ui(14, .semibold)).foregroundStyle(G.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(shortDate(r.created)).frame(width: 112, alignment: .leading)
            Text(formatTime(r.duration)).font(GFont.mono(13)).frame(width: 72, alignment: .leading)
            Group {
                if let p = running(r) { MiniProgress(progress: p) }
                else { Text(r.results.isEmpty ? "None yet" : "\(r.results.count) transcript\(r.results.count == 1 ? "" : "s")") }
            }
            .frame(width: 128, alignment: .leading)
            Chip(text: r.callLanguage.title).frame(width: 132, alignment: .leading)
        }
        .font(GFont.ui(13))
        .foregroundStyle(G.text2)
        .padding(.horizontal, 16).frame(height: 52)
        .background(selected ? G.accentSoft.opacity(0.7) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(G.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { tap(r) }
        .draggable("r:" + r.id)
        .contextMenu {
            Button("Open") { ui.open(recording: r.id, folder: ui.folder ?? r.folderID) }
            Button(ui.selectedIDs.count > 1 && selected ? "Export \(ui.selectedIDs.count) recordings…" : "Export…") {
                ui.modal = .export(ids: ui.selectedIDs.count > 1 && selected ? orderedSelection() : [r.id])
            }
            Divider()
            Button("Move to…") { ui.modal = .moveRecording(r) }
            Menu("Move to") {
                Button("Library (top level)") { move(r, to: nil) }.disabled(r.folderID == nil)
                Divider()
                ForEach(store.flatFolders(), id: \.folder.id) { item in
                    Button(item.path) { move(r, to: item.folder.id) }.disabled(r.folderID == item.folder.id)
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { ui.modal = .deleteRecording(r) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Click opens; Command or Shift click (or the Select button) selects. Shift extends from the last click.
    private func tap(_ r: Recording) {
        let flags = NSEvent.modifierFlags
        if ui.selectionMode || flags.contains(.command) || flags.contains(.shift) {
            ui.selectionMode = true
            if flags.contains(.shift), let a = anchor, let i = rows.firstIndex(where: { $0.id == a }),
               let j = rows.firstIndex(where: { $0.id == r.id }) {
                for x in rows[min(i, j)...max(i, j)] { ui.selectedIDs.insert(x.id) }
            } else if ui.selectedIDs.contains(r.id) {
                ui.selectedIDs.remove(r.id)
            } else {
                ui.selectedIDs.insert(r.id)
            }
            anchor = r.id
        } else {
            ui.open(recording: r.id, folder: ui.folder ?? r.folderID)
        }
    }

    /// Selected ids in the order they appear in the list.
    private func orderedSelection() -> [String] {
        rows.map(\.id).filter { ui.selectedIDs.contains($0) }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(ui.selectedIDs.count) selected").font(GFont.ui(13, .semibold))
            Button("Select all") { ui.selectedIDs = Set(rows.map(\.id)) }.buttonStyle(.g(.quiet, height: 28))
            Button("Clear") { ui.selectedIDs = [] }.buttonStyle(.g(.quiet, height: 28)).disabled(ui.selectedIDs.isEmpty)
            Spacer()
            Button { ui.modal = .export(ids: orderedSelection()) } label: { IconLabel("Export…", "square.and.arrow.up") }
                .buttonStyle(.g(.primary, height: 32)).disabled(ui.selectedIDs.isEmpty)
            Button("Done") { ui.endSelection() }.buttonStyle(.g(.secondary, height: 32))
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(G.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(G.accent))
    }

    private func move(_ r: Recording, to target: String?) {
        store.setFolder(r.id, target)
        let f = store.folder(target)
        ui.toast("Moved to \(f?.name ?? "Library")", icon: f == nil ? "tray.full" : nil, swatch: f?.color.swiftUI)
    }

    // MARK: Empty

    private var emptyState: some View {
        let first = store.recordings.isEmpty && folder == nil
        return VStack(spacing: 16) {
            if first {
                LogoMark(size: 64)
            } else {
                GIcon("folder", size: 24).foregroundStyle(G.accentText)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(G.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(G.borderStrong))
            }
            Text(first ? "No recordings yet" : "Nothing in \(folder?.name ?? "Library") yet")
                .font(GFont.ui(18, .semibold)).tracking(-0.2)
            Text(first
                 ? "Record a meeting or import an audio file. Scribe transcribes on this Mac by default, and nothing leaves it unless you choose a cloud model."
                 : "Record straight into this folder, or import audio you already have. You can also drag recordings here from other folders.")
                .font(GFont.ui(14)).foregroundStyle(G.text2).lineSpacing(4).multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button { ui.goRecord() } label: { IconLabel(first ? "New recording" : "Record into this folder", "mic") }
                    .buttonStyle(.g(.primary, height: 40))
                Button { ui.section = .importAudio } label: {
                    IconLabel(first ? "Import audio" : "Import into this folder", "square.and.arrow.down")
                }
                .buttonStyle(.g(.secondary, height: 40))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
    }
}

// MARK: - Folder dialogs

enum FolderDialogMode {
    case create(parent: String?)
    case edit(Folder)
}

struct FolderDialog: View {
    let mode: FolderDialogMode
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var ui: UIState
    @State private var name = ""
    @State private var color: FolderColor = .blue
    @State private var ready = false

    private var parentID: String? {
        switch mode {
        case .create(let p): return p
        case .edit(let f): return f.parentID
        }
    }

    private var title: String {
        switch mode {
        case .create: return "New folder"
        case .edit: return "Rename or recolor folder"
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var isEdit: Bool { if case .edit = mode { return true } else { return false } }
    private var previewCount: Int { if case .edit(let f) = mode { return store.recordingCount(in: f.id) } else { return 0 } }

    var body: some View {
        ModalScrim(onCancel: { ui.modal = nil }) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(GFont.ui(20, .semibold)).tracking(-0.4)
                    Text(isEdit ? "Recordings and subfolders inside it stay exactly where they are."
                                : "Folders can be nested as deep as you like.")
                        .font(GFont.ui(13)).foregroundStyle(G.text2)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Name")
                    GField(placeholder: "Folder name, for example Daily standups", text: $name, autofocus: true, onSubmit: save)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Location")
                    HStack(spacing: 8) {
                        GIcon("folder", size: 12).foregroundStyle(G.text3)
                        if let p = store.folder(parentID) { FolderSwatch(color: p.color.swiftUI) }
                        Text(store.path(of: parentID)).font(GFont.ui(13)).foregroundStyle(G.text2).lineLimit(1)
                        Spacer(minLength: 0)
                        if isEdit { Text("Use Move to to change").font(GFont.ui(12)).foregroundStyle(G.text3) }
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.borderStrong))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel("Colour")
                        Spacer()
                        Text(color.label).font(GFont.ui(13)).foregroundStyle(G.text2)
                    }
                    HStack(spacing: 8) {
                        ForEach(FolderColor.allCases) { c in swatch(c) }
                    }
                    .padding(.horizontal, 4).padding(.top, 4)
                }
                HStack(spacing: 10) {
                    SectionLabel("Preview")
                    FolderSwatch(color: color.swiftUI, size: 12).padding(.leading, 8)
                    Text(trimmed.isEmpty ? "Folder name" : trimmed).font(GFont.ui(14, .medium))
                        .foregroundStyle(trimmed.isEmpty ? G.text3 : G.text)
                    Spacer()
                    Text("\(previewCount)").font(GFont.mono(11)).foregroundStyle(G.text3)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { ui.modal = nil }.buttonStyle(.gSecondary)
                    Button("Save", action: save).buttonStyle(.gPrimary).disabled(trimmed.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            if case .edit(let f) = mode { name = f.name; color = f.color }
        }
    }

    private func swatch(_ c: FolderColor) -> some View {
        let on = color == c
        return Button { color = c } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.swiftUI)
                if on { GIcon("checkmark", size: 13, weight: .heavy).foregroundStyle(G.bg) }
            }
            .frame(width: 32, height: 32)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(G.text, lineWidth: on ? 2 : 0).padding(-4))
        }
        .buttonStyle(.plain)
        .help(c.label)
        .accessibilityLabel(c.label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .padding(.trailing, 2)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .create(let parent):
            let f = store.createFolder(name: trimmed, color: color, parent: parent)
            ui.toast("Folder “\(f.name)” created", icon: nil, swatch: f.color.swiftUI)
        case .edit(let f):
            store.updateFolder(f.id, name: trimmed, color: color)
            ui.toast("Saved")
        }
        ui.modal = nil
    }
}

struct DeleteFolderDialog: View {
    let folder: Folder
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var ui: UIState

    private var parentName: String { store.folder(folder.parentID)?.name ?? "Library" }
    private var childFolders: [Folder] { store.children(of: folder.id) }
    private var directRecordings: Int { store.recordings(in: folder.id).count }

    var body: some View {
        ModalScrim(onCancel: { ui.modal = nil }) {
            VStack(alignment: .leading, spacing: 18) {
                DialogHeader(icon: "trash", danger: true, title: "Delete “\(folder.name)”?",
                             message: "Recordings and subfolders inside it move up one level, into \(parentName). No audio is deleted.")
                HStack(alignment: .top, spacing: 12) {
                    tree("Before", rows: [(0, parentName, nil), (1, folder.name, folder.color.swiftUI)]
                         + childFolders.map { (2, $0.name, $0.color.swiftUI) }, struck: folder.name)
                    tree("After", rows: [(0, parentName, nil)] + childFolders.map { (1, $0.name, $0.color.swiftUI) }, struck: nil)
                }
                if directRecordings > 0 {
                    Text("\(directRecordings) recording\(directRecordings == 1 ? "" : "s") move up with the folder contents.")
                        .font(GFont.ui(12)).foregroundStyle(G.text3)
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") { ui.modal = nil }.buttonStyle(.g(.secondary, height: 36))
                    Button("Delete folder") {
                        if ui.folder == folder.id { ui.folder = folder.parentID }
                        store.deleteFolder(folder.id)
                        ui.modal = nil
                        ui.toast("Folder “\(folder.name)” deleted", icon: "trash")
                    }
                    .buttonStyle(.g(.danger, height: 36))
                }
            }
        }
    }

    private func tree(_ title: String, rows: [(Int, String, Color?)], struck: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 6) {
                        if let c = r.2 { FolderSwatch(color: c) } else { GIcon("tray.full", size: 10).foregroundStyle(G.text3) }
                        Text(r.1).font(GFont.ui(12)).strikethrough(struck == r.1 && r.0 == 1, color: G.danger)
                            .foregroundStyle(struck == r.1 && r.0 == 1 ? G.danger : G.text2).lineLimit(1)
                    }
                    .padding(.leading, CGFloat(r.0) * 14)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.border))
        }
    }
}
