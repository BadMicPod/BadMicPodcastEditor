import SwiftUI

/// Receives files dropped on the Dock icon or opened with the app from Finder. They can arrive
/// before the editor exists, so they wait until it does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var pending: [URL] = []

    @MainActor weak var model: EditorModel? {
        didSet { flush() }
    }

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS adds Services to the app menu, and Writing Tools, AutoFill, Start Dictation and Emoji &
        // Symbols to the Edit menu. None of them help with editing video, so they come out once the menus
        // exist, and again whenever they're put back (SwiftUI rebuilds menus as commands change).
        DispatchQueue.main.async { MenuCleanup.removeExtras() }
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu, menu.supermenu === NSApp.mainMenu else { return }
                MenuCleanup.removeExtras(in: menu)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.autosaveNow() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            pending += urls
            flush()
        }
    }

    @MainActor private func flush() {
        guard let model, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        model.handleOpen(urls)
    }
}

/// Takes macOS's extra menu items back out, found by what they do rather than their titles so it holds in
/// any language, then tidies the separators they leave behind.
@MainActor
enum MenuCleanup {
    static func removeExtras() {
        for top in NSApp.mainMenu?.items ?? [] {
            if let menu = top.submenu { removeExtras(in: menu) }
        }
    }

    static func removeExtras(in menu: NSMenu) {
        menu.items.filter(isExtra).forEach(menu.removeItem)
        // No separator at either end of a menu, or two in a row.
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        for i in stride(from: menu.items.count - 1, to: 0, by: -1) where menu.items[i].isSeparatorItem && menu.items[i - 1].isSeparatorItem {
            menu.removeItem(at: i)
        }
    }

    private static func isExtra(_ item: NSMenuItem) -> Bool {
        let actions: Set<String> = ["startDictation:", "orderFrontCharacterPalette:"]
        let identifiers: Set<String> = ["__NSTextViewContextSubmenuIdentifierWritingTools", "_NSMenuItemAutoFillIdentifier",
                                        "_NSMenuItemLegacyWritingToolsSeparatorIdentifier"]
        if let services = NSApp.servicesMenu, item.submenu === services { return true }
        return item.identifier.map { identifiers.contains($0.rawValue) } == true
            || item.action.map { actions.contains(NSStringFromSelector($0)) } == true
    }
}

@main
struct CutAndPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = EditorModel()

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        Window("Cut and Play", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1480, height: 940)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { model.newProject() }.keyboardShortcut("n")
                Button("Open…") { model.openProject() }.keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recentProjects, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.openRecent(url) }
                    }
                    if !model.recentProjects.isEmpty { Divider() }
                    Button("Clear Menu") { model.clearRecents() }
                        .disabled(model.recentProjects.isEmpty)
                }
                Divider()
                Button("Save") { model.save() }.keyboardShortcut("s")
                Button("Save As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Import Media…") { model.showImportPanel() }.keyboardShortcut("i")
                Button("Export…") { model.showExport = true }.keyboardShortcut("e")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z")
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Clip") {
                Button("Split at Playhead") { model.splitAtPlayhead() }.keyboardShortcut("k")
                Button("Add Dissolve") { model.addTransitionAtPlayhead() }.keyboardShortcut("d")
                Button("Even Out Audio Levels") { model.evenOutLevels() }
                Button("Detach Audio") { model.detachAudio() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Duplicate") { model.duplicateSelection() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Delete") { model.deleteSelection() }
                Button("Ripple Delete") { model.deleteSelection(ripple: true) }
                Button("Close All Gaps") { model.closeAllGaps() }
                Divider()
                Button("Add Text") { model.addAtPlayhead(.text) }.keyboardShortcut("t")
                Button("Add Solid") { model.addAtPlayhead(.solid) }
                Divider()
                Button("Add Video Track") { model.addTrack(.video) }
                Button("Add Audio Track") { model.addTrack(.audio) }
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { model.zoom(by: 1.4) }.keyboardShortcut("=")
                Button("Zoom Out") { model.zoom(by: 1 / 1.4) }.keyboardShortcut("-")
                Button("Zoom to Fit") { model.zoomToFit() }.keyboardShortcut("0")
                Divider()
                Button(model.snapping ? "Turn Snapping Off" : "Turn Snapping On") { model.snapping.toggle() }
                Divider()
            }
        }
    }
}
