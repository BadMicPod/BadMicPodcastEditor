import AppKit
import SwiftUI

/// Over the whole window: files dragged in from another app (outside the timeline, which places them itself) are
/// caught here, so the drop can tell macOS how to finish: their pictures vanish as they're let go and the files are
/// in Media at once, rather than macOS's fade where they were let go. Every click, scroll and hover passes through to what's below,
/// and so do drags that start in Editroom.
struct WindowDropCatcher: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.model = model
        v.registerForDraggedTypes([.fileURL])
        return v
    }

    func updateNSView(_ v: Catcher, context: Context) { v.model = model }

    final class Catcher: NSView {
        weak var model: EditorModel?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only while a drag from another app is over the window: the mouse button is down, but the event
            // isn't one of Editroom's own clicks or drags.
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return nil }
            if let e = NSApp.currentEvent, e.window != nil,
               [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                .otherMouseDragged, .otherMouseUp, .scrollWheel].contains(e.type) { return nil }
            // The timeline places what's dropped on it, where it's dropped.
            if let timeline = MainActor.assumeIsolated({ TimelineCanvas.current }), timeline.window == window,
               let local = superview.map({ convert($0.convert(point, to: nil), from: nil) }),
               timeline.convert(timeline.bounds, to: self).contains(local) { return nil }
            return super.hitTest(point) == nil ? nil : self
        }

        private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard !fileURLs(sender).isEmpty else { return [] }
            MainActor.assumeIsolated { model?.importDropHover = true }
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            fileURLs(sender).isEmpty ? [] : .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            MainActor.assumeIsolated { model?.importDropHover = false }
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !fileURLs(sender).isEmpty }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = fileURLs(sender)
            guard !urls.isEmpty else { return false }
            // No drop animation: the dragged pictures vanish the moment they're let go (they're in Media at once).
            sender.animatesToDestination = true
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self], searchOptions: [:]) { item, _, _ in
                item.imageComponentsProvider = { [] }
            }
            // Imported at once: the pictures jump straight into Media (the import keeps the main thread busy through
            // the animation, which reads as an instant hand-off, and was preferred over waiting for a glide).
            MainActor.assumeIsolated {
                model?.importDropHover = false
                model?.handleOpen(urls)
            }
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            MainActor.assumeIsolated { model?.importDropHover = false }
        }
    }
}
