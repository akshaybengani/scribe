import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let store = RecordingStore()
    private let settings = AppSettings()
    private let ui = UIState()
    private lazy var jobs = JobRunner(store: store, settings: settings)
    private lazy var search = SearchModel(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Inter and JetBrains Mono live in Contents/Resources/Fonts. Register them before the first view exists.
        GFont.registerBundled()
        buildMenu()
        // No forced appearance: the window follows the system light or dark setting.
        let root = ContentView()
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(jobs)
            .environmentObject(ui)
            .environmentObject(search)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Scribe"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 940, height: 660)
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("ScribeWindow") { window.center() }
        window.setFrameAutosaveName("ScribeWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // MARK: Menu actions

    @objc private func newRecording() { ui.goRecord() }
    @objc private func newFolder() { ui.modal = .newFolder(parent: ui.folder) }
    @objc private func openSettings() { ui.openSettings() }
    @objc private func exportTranscript() { ui.exportHandler?() }
    @objc private func openSearch() { ui.focusSearch() }
    @objc private func findInTranscript() { ui.findToken += 1 }
    @objc private func showShortcuts() { ui.modal = .shortcuts }
    @objc private func showAbout() { ui.modal = .about }

    private func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    /// Built by hand because there is no nib: without this Cmd-Q and the text-editing shortcuts do not exist.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("About Scribe", #selector(showAbout), "", []))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Scribe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Scribe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Recording", #selector(newRecording), "n"))
        fileMenu.addItem(item("New Folder", #selector(newFolder), "n", [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Export Transcript…", #selector(exportTranscript), "e"))
        fileMenu.addItem(item("Search Recordings…", #selector(openSearch), "k"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(item("Find in Transcript", #selector(findInTranscript), "f"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Keyboard Shortcuts", #selector(showShortcuts), "/"))
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
        NSApp.helpMenu = helpMenu
        NSApp.windowsMenu = windowMenu
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    objc_setAssociatedObject(app, "ScribeAppDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
