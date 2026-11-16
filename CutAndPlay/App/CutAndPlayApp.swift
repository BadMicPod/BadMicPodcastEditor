import SwiftUI

@main
struct CutAndPlayApp: App {
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
