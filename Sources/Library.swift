import SwiftUI
import AppKit

extension FolderColor {
    var swiftUI: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }

    var label: String { rawValue.capitalized }
}

private struct TreeNode: Identifiable {
    enum Kind {
        case folder(Folder)
        case recording(Recording)
    }
    let id: String          // "f:<folder id>" or "r:<recording id>"
    let kind: Kind
    var children: [TreeNode]?
}

private enum FolderSheetMode: Identifiable {
    case create(parent: String?)
    case edit(Folder)

    var id: String {
        switch self {
        case .create(let p): return "create-" + (p ?? "root")
        case .edit(let f): return "edit-" + f.id
        }
    }
}

/// The library: nested, colour-coded folders with recordings inside them.
struct LibrarySidebar: View {
    @EnvironmentObject var store: RecordingStore
    @Binding var selection: String?     // selected recording
    @Binding var folder: String?        // folder new recordings go into (nil = top level)
    @State private var sheet: FolderSheetMode?
    @State private var pendingDelete: Folder?

    private func nodes(parent: String?) -> [TreeNode] {
        let folders = store.children(of: parent).map { f -> TreeNode in
            let kids = nodes(parent: f.id)
            return TreeNode(id: "f:" + f.id, kind: .folder(f), children: kids.isEmpty ? nil : kids)
        }
        let recs = store.recordings(in: parent).map { TreeNode(id: "r:" + $0.id, kind: .recording($0), children: nil) }
        return folders + recs
    }

    private var listSelection: Binding<String?> {
        Binding(
            get: {
                if let s = selection { return "r:" + s }
                if let f = folder { return "f:" + f }
                return nil
            },
            set: { new in
                guard let new else { selection = nil; return }
                if new.hasPrefix("r:") {
                    let id = String(new.dropFirst(2))
                    selection = id
                    folder = store.recordings.first { $0.id == id }?.folderID
                } else if new.hasPrefix("f:") {
                    selection = nil
                    folder = String(new.dropFirst(2))
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { selection = nil } label: { Label("New recording", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderless)
                Spacer()
                Button { sheet = .create(parent: folder) } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("New folder" + (folder == nil ? "" : " inside \(store.path(of: folder))"))
            }
            .padding(12)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
                Text(folder == nil ? "Library" : store.path(of: folder)).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if folder != nil {
                    Button("Top level") { folder = nil; selection = nil }.buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            List(nodes(parent: nil), children: \.children, selection: listSelection) { node in
                row(node)
            }
            .dropDestination(for: String.self) { items, _ in drop(items, onto: nil) }
        }
        .sheet(item: $sheet) { mode in FolderSheet(mode: mode) }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                if let f = pendingDelete {
                    if folder == f.id { folder = f.parentID }
                    store.deleteFolder(f.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Recordings and subfolders inside it move up one level. No audio is deleted.")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ node: TreeNode) -> some View {
        switch node.kind {
        case .folder(let f):
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(f.color.swiftUI)
                Text(f.name).lineLimit(1)
                Spacer()
                Text("\(store.recordingCount(in: f.id))").font(.caption).foregroundStyle(.secondary)
            }
            .tag(node.id as String?)
            .contentShape(Rectangle())
            .draggable("f:" + f.id)
            .dropDestination(for: String.self) { items, _ in drop(items, onto: f.id) }
            .contextMenu {
                Button("New folder inside") { sheet = .create(parent: f.id) }
                Button("Rename or recolor…") { sheet = .edit(f) }
                Menu("Move to") { moveFolderMenu(f) }
                Divider()
                Button("Delete folder…", role: .destructive) { pendingDelete = f }
            }
        case .recording(let r):
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(r.created, style: .date)
                    Text("· " + formatTime(r.duration))
                    if !r.results.isEmpty { Text("· \(r.results.count) transcript\(r.results.count == 1 ? "" : "s")") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .tag(node.id as String?)
            .draggable("r:" + r.id)
            .contextMenu {
                Menu("Move to") { moveRecordingMenu(r) }
                Divider()
                Button("Delete", role: .destructive) {
                    if selection == r.id { selection = nil }
                    store.delete(r.id)
                }
            }
        }
    }

    @ViewBuilder
    private func moveRecordingMenu(_ r: Recording) -> some View {
        Button("Library (top level)") { store.setFolder(r.id, nil) }.disabled(r.folderID == nil)
        Divider()
        ForEach(store.flatFolders(), id: \.folder.id) { item in
            Button(item.path) { store.setFolder(r.id, item.folder.id) }.disabled(r.folderID == item.folder.id)
        }
    }

    @ViewBuilder
    private func moveFolderMenu(_ f: Folder) -> some View {
        Button("Library (top level)") { store.moveFolder(f.id, to: nil) }.disabled(f.parentID == nil)
        Divider()
        ForEach(store.flatFolders(excluding: store.descendantIDs(of: f.id)), id: \.folder.id) { item in
            Button(item.path) { store.moveFolder(f.id, to: item.folder.id) }.disabled(f.parentID == item.folder.id)
        }
    }

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
        return moved
    }
}

private struct FolderSheet: View {
    let mode: FolderSheetMode
    @EnvironmentObject var store: RecordingStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: FolderColor = .blue

    private var title: String {
        switch mode {
        case .create(let p): return p == nil ? "New folder" : "New folder in \(store.path(of: p))"
        case .edit: return "Rename or recolor folder"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Folder name, for example Daily standups", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack(spacing: 10) {
                ForEach(FolderColor.allCases) { c in
                    Button { color = c } label: {
                        Circle().fill(c.swiftUI).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.primary, lineWidth: color == c ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(c.label)
                    .accessibilityLabel(c.label)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if case .edit(let f) = mode { name = f.name; color = f.color }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        switch mode {
        case .create(let parent): store.createFolder(name: n, color: color, parent: parent)
        case .edit(let f): store.updateFolder(f.id, name: n, color: color)
        }
        dismiss()
    }
}
