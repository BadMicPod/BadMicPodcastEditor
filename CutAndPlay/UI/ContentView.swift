import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: EditorModel
    @State private var libraryWidth: CGFloat = 252
    @State private var timelineHeight: CGFloat = 360

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    LibraryView(model: model, media: model.media)
                        .frame(width: libraryWidth)
                    Splitter(vertical: true) { x in
                        libraryWidth = min(440, max(190, x - frame.minX))
                    }
                    PreviewView(model: model)
                    Hairline(vertical: true)
                    InspectorView(model: model)
                        .frame(width: 252)
                }
                Splitter(vertical: false) { y in
                    timelineHeight = min(max(200, geo.size.height - 240), max(170, frame.maxY - y))
                }
                TimelinePanel(model: model)
                    .frame(height: min(timelineHeight, max(170, geo.size.height - 240)))
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                    if model.isDirty {
                        Circle().fill(Theme.textFaint).frame(width: 5, height: 5)
                    }
                }
            }
            .withoutGlass()
            ToolbarItem(placement: .primaryAction) {
                PillButton(title: "Export", prominent: true) { model.showExport = true }
                    .help("Export (⌘E)")
            }
            .withoutGlass()
        }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(model: model, exporter: model.exporter)
        }
        .alert("Import", isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importError ?? "")
        }
        .onAppear { KeyCommands.install(model) }
    }
}

/// Bare-key shortcuts (space, V, C, arrows…) that should work anywhere except while typing.
@MainActor
enum KeyCommands {
    private static var installed = false

    static func install(_ model: EditorModel) {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event, model) ? nil : event }
        }
    }

    private static func handle(_ e: NSEvent, _ model: EditorModel) -> Bool {
        // Only the main editor window gets bare-key shortcuts; sheets and panels keep Return/Esc for themselves.
        guard let window = NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil,
              !(window is NSPanel) else { return false }
        if let responder = window.firstResponder, responder is NSText { return false }
        let flags = e.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        let shift = e.modifierFlags.contains(.shift)

        switch e.keyCode {
        case 49: model.togglePlay()
        case 51, 117: model.deleteSelection(ripple: shift)
        case 123: model.step(frames: shift ? -10 : -1)
        case 124: model.step(frames: shift ? 10 : 1)
        case 126: model.jumpToEdit(forward: false)
        case 125: model.jumpToEdit(forward: true)
        case 115: model.seek(to: 0)
        case 119: model.seek(to: model.project.duration)
        case 53:
            model.selection = []
            model.tool = .move
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "v": model.tool = .move
            case "c": model.tool = .cut
            case "s": model.snapping.toggle()
            case "z" where shift, "\\": model.zoomToFit()
            case "=", "+": model.zoom(by: 1.4)
            case "-": model.zoom(by: 1 / 1.4)
            default: return false
            }
        }
        return true
    }
}

extension ToolbarContent {
    /// Opts a toolbar item out of the system's shared glass background where that exists.
    @ToolbarContentBuilder
    func withoutGlass() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
