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
                Divider()
                Button("Delete") { model.deleteSelection() }
                Button("Ripple Delete") { model.deleteSelection(ripple: true) }
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
