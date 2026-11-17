import SwiftUI
import AppKit

// MARK: - Dialog layer

struct ModalLayer: View {
    let modal: AppModal
    var body: some View {
        switch modal {
        case .newFolder(let parent): FolderDialog(mode: .create(parent: parent))
        case .editFolder(let f): FolderDialog(mode: .edit(f))
        case .deleteFolder(let f): DeleteFolderDialog(folder: f)
        case .deleteRecording(let r): DeleteRecordingDialog(recording: r)
        case .confirmCloud(let r, let k): CloudConfirmDialog(recording: r, kind: k)
        case .export(let ids): ExportDialog(ids: ids)
        case .moveRecording(let r): MoveRecordingDialog(recording: r)
        case .deleteAll: DeleteAllDialog()
        case .shortcuts: ShortcutsDialog()
        case .about: AboutDialog()
        }
    }
}

struct DialogHeader: View {
    let icon: String
    let danger: Bool
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GIcon(icon, size: 18)
                .foregroundStyle(danger ? G.danger : G.warnIcon)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(danger ? G.dangerSoft : G.warnBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(danger ? G.danger : G.warnBorder))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(GFont.ui(18, .semibold)).tracking(-0.2)
                Text(message).font(GFont.ui(14)).foregroundStyle(G.text2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Cloud confirmation

struct CloudConfirmDialog: View {
    let recording: Recording
    let kind: ProviderKind
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var jobs: JobRunner
    @EnvironmentObject var settings: AppSettings

    private var message: String {
        kind.hearsAudio
            ? "This audio will be uploaded to \(kind.company), a third-party platform, for processing."
            : "The existing transcripts (text only, no audio) will be sent to \(kind.company), a third-party platform."
    }

    var body: some View {
        ModalScrim(onCancel: { ui.modal = nil }) {
            VStack(alignment: .leading, spacing: 18) {
                DialogHeader(icon: "cloud", danger: false, title: "Send to \(kind.company)?", message: message)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        GIcon("checkmark", size: 12, weight: .bold).foregroundStyle(G.success)
                        Text(kind.hearsAudio ? "The recording stays saved on this Mac." : "No audio leaves this Mac.")
                            .font(GFont.ui(13))
                    }
                    HStack(spacing: 10) {
                        GIcon("mic", size: 12).foregroundStyle(G.text2)
                        (Text(recording.title + ", ")
                         + Text(formatTime(recording.duration)).font(GFont.mono(12))
                         + Text(", " + recording.callLanguage.title))
                            .font(GFont.ui(13)).foregroundStyle(G.text2).lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        GIcon("cpu", size: 12).foregroundStyle(G.text2)
                        Text(settings.name(kind, language: recording.callLanguage)).font(GFont.mono(12)).foregroundStyle(G.text2)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
                if kind.hearsAudio, let w = SpeakerSupport.longRecordingWarning(kind, settings: settings, seconds: recording.duration) {
                    HStack(alignment: .top, spacing: 8) {
                        GIcon("exclamationmark.triangle.fill", size: 12).foregroundStyle(G.warnIcon).padding(.top, 1)
                        Text(w).font(GFont.ui(12)).foregroundStyle(G.warnText).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.warnBg))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.warnBorder))
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") { ui.modal = nil }.buttonStyle(.g(.secondary, height: 36))
                    Button("Send to \(kind.company)") {
                        jobs.start(recording, kind: kind)
                        ui.modal = nil
                    }
                    .buttonStyle(.g(.primary, height: 36))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Deleting

struct DeleteRecordingDialog: View {
    let recording: Recording
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var store: RecordingStore

    var body: some View {
        ModalScrim(onCancel: { ui.modal = nil }) {
            VStack(alignment: .leading, spacing: 18) {
                DialogHeader(icon: "trash", danger: true, title: "Delete this recording?",
                             message: "“\(recording.title)” will be deleted from this Mac, together with its audio and its \(recording.results.count) transcript\(recording.results.count == 1 ? "" : "s"). This cannot be undone.")
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") { ui.modal = nil }.buttonStyle(.g(.secondary, height: 36))
                    Button("Delete recording") {
                        if ui.selection == recording.id { ui.selection = nil }
                        ui.selectedIDs.remove(recording.id)
                        store.delete(recording.id)
                        ui.modal = nil
                        ui.toast("Recording deleted", icon: "trash")
                    }
                    .buttonStyle(.g(.danger, height: 36))
                }
            }
        }
    }
}

struct DeleteAllDialog: View {
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var store: RecordingStore
    @State private var typed = ""

    var body: some View {
        let n = store.recordings.count
        ModalScrim(onCancel: { ui.modal = nil }) {
            VStack(alignment: .leading, spacing: 18) {
                DialogHeader(icon: "trash", danger: true, title: "Delete all recordings?",
                             message: "This removes every recording, its audio and its transcripts from this Mac. Folders stay. This cannot be undone.")
                VStack(alignment: .leading, spacing: 8) {
                    (Text("Type ") + Text("DELETE").font(GFont.mono(13, .medium)) + Text(" to confirm deleting \(n) recording\(n == 1 ? "" : "s")."))
                        .font(GFont.ui(13)).foregroundStyle(G.text2)
                    GField(placeholder: "DELETE", text: $typed, mono: true, autofocus: true)
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") { ui.modal = nil }.buttonStyle(.g(.secondary, height: 36))
                    Button("Delete \(n) recording\(n == 1 ? "" : "s")") {
                        for r in store.recordings { store.delete(r.id) }
                        ui.selection = nil
                        ui.modal = nil
                        ui.toast("All recordings deleted", icon: "trash")
                    }
                    .buttonStyle(.g(.danger, height: 36))
                    .disabled(typed != "DELETE")
                }
            }
        }
    }
}

// MARK: - Move to

/// "Move to…" for one recording: pick a folder from the tree, then Move here.
struct MoveRecordingDialog: View {
    let recording: Recording
    @EnvironmentObject var store: RecordingStore
    @EnvironmentObject var ui: UIState
    @State private var target: String?
    @State private var ready = false

    var body: some View {
        ModalScrim(onCancel: { ui.modal = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move to").font(GFont.ui(20, .semibold)).tracking(-0.4)
                    HStack(spacing: 6) {
                        Text("“\(recording.title)”, now in").lineLimit(1)
                        if let f = store.folder(recording.folderID) { FolderSwatch(color: f.color.swiftUI) }
                        Text(store.path(of: recording.folderID)).lineLimit(1)
                    }
                    .font(GFont.ui(13)).foregroundStyle(G.text2)
                }
                ScrollView {
                    VStack(spacing: 1) {
                        row(id: nil, name: "Library (top level)", color: nil, depth: 0)
                        ForEach(store.flatFolders(), id: \.folder.id) { item in
                            row(id: item.folder.id, name: item.folder.name, color: item.folder.color.swiftUI,
                                depth: item.path.components(separatedBy: " / ").count - 1)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 260)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") { ui.modal = nil }.buttonStyle(.g(.secondary, height: 36))
                    Button("Move here") {
                        store.setFolder(recording.id, target)
                        let f = store.folder(target)
                        ui.modal = nil
                        ui.toast("Moved to \(f?.name ?? "Library")", icon: f == nil ? "tray.full" : nil, swatch: f?.color.swiftUI)
                    }
                    .buttonStyle(.g(.primary, height: 36)).keyboardShortcut(.defaultAction)
                    .disabled(target == recording.folderID)
                }
            }
        }
        .onAppear { if !ready { ready = true; target = recording.folderID } }
    }

    private func row(id: String?, name: String, color: Color?, depth: Int) -> some View {
        let on = target == id
        let current = recording.folderID == id
        return Button { target = id } label: {
            HStack(spacing: 8) {
                if let color { FolderSwatch(color: color) } else { GIcon("tray.full", size: 12).foregroundStyle(G.text3) }
                Text(name).font(GFont.ui(13, .medium)).lineLimit(1)
                Spacer()
                if current { Text("Current location").font(GFont.ui(11)).foregroundStyle(G.text3) }
                if on { GIcon("checkmark", size: 11, weight: .bold).foregroundStyle(G.accentText) }
            }
            .foregroundStyle(on ? G.text : G.text2)
            .padding(.leading, 10 + CGFloat(depth) * 16).padding(.trailing, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? G.surface3 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Shortcuts and About

struct ShortcutsDialog: View {
    @EnvironmentObject var ui: UIState

    private let groups: [(String, [(String, String)])] = [
        ("General", [("Search recordings, folders and transcripts", "⌘K"), ("Open Settings", "⌘,"),
                     ("Show this reference", "⌘/"), ("Close a dialog or the search panel", "Esc")]),
        ("Recording", [("New recording", "⌘N"), ("Start or stop recording", "⌘R"), ("New folder", "⇧⌘N")]),
        ("Recording detail", [("Play or pause", "Space"), ("Find in the transcript", "⌘F"),
                              ("Next or previous match", "⌘G / ⇧⌘G"), ("Export transcript", "⌘E")]),
    ]

    var body: some View {
        ModalScrim(onCancel: { ui.modal = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keyboard shortcuts").font(GFont.ui(20, .semibold)).tracking(-0.4)
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(group.0)
                        ForEach(group.1, id: \.0) { item in
                            HStack {
                                Text(item.0).font(GFont.ui(13)).foregroundStyle(G.text)
                                Spacer()
                                Text(item.1).font(GFont.mono(12)).foregroundStyle(G.text2)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(G.surface2))
                                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(G.borderStrong))
                            }
                        }
                    }
                }
                HStack { Spacer(); Button("Done") { ui.modal = nil }.buttonStyle(.g(.primary, height: 36)).keyboardShortcut(.defaultAction) }
            }
        }
    }
}

struct AboutDialog: View {
    @EnvironmentObject var ui: UIState

    var body: some View {
        ModalScrim(onCancel: { ui.modal = nil }) {
            VStack(spacing: 14) {
                LogoMark(size: 72)
                VStack(spacing: 4) {
                    Text("Scribe").font(GFont.ui(22, .semibold)).tracking(-0.4)
                    Text("Version 0.1 (build 1)").font(GFont.mono(12)).foregroundStyle(G.text3)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("The local-first promise").font(GFont.ui(13, .semibold))
                    promise("Your recordings and transcripts stay on this Mac, in a folder you can open.")
                    promise("Nothing is uploaded unless you choose a cloud model, and Scribe tells you which provider gets what.")
                    promise("API keys live in the macOS Keychain, never in a file.")
                    promise("Claude text review reads transcript text only. It never receives audio.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
                HStack(spacing: 10) {
                    Button { ui.modal = nil; ui.openSettings(.storage) } label: { IconLabel("See what leaves this Mac", "lock.shield") }
                        .buttonStyle(.g(.secondary, height: 36))
                    Button("Close") { ui.modal = nil }.buttonStyle(.g(.primary, height: 36)).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func promise(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            GIcon("checkmark", size: 11, weight: .bold).foregroundStyle(G.success).padding(.top, 3)
            Text(text).font(GFont.ui(13)).foregroundStyle(G.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
