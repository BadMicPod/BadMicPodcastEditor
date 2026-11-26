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
        // Files, and files another app promises (Photos, Mail).
        v.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
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

        /// Files another app will write when asked (Photos, whose library can't be read directly).
        private func promises(_ info: NSDraggingInfo) -> [NSFilePromiseReceiver] {
            info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        }

        private func accepts(_ info: NSDraggingInfo) -> Bool { !fileURLs(info).isEmpty || !promises(info).isEmpty }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard accepts(sender) else { return [] }
            MainActor.assumeIsolated { model?.importDropHover = true }
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            accepts(sender) ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            MainActor.assumeIsolated { model?.importDropHover = false }
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            // A promise wins: Photos puts a ready-made preview picture of a video on the drag as a file, and the video
            // itself only as a promise. Finder never promises, so its files are taken as they are.
            let promised = promises(sender)
            let urls = promised.isEmpty ? fileURLs(sender) : []
            guard !urls.isEmpty || !promised.isEmpty else { return false }
            // No drop animation: the dragged pictures vanish the moment they're let go (they're in Media at once).
            sender.animatesToDestination = true
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self, NSFilePromiseReceiver.self], searchOptions: [:]) { item, _, _ in
                item.imageComponentsProvider = { [] }
            }
            // Imported at once: the pictures jump straight into Media (the import keeps the main thread busy through
            // the animation, which reads as an instant hand-off, and was preferred over waiting for a glide).
            MainActor.assumeIsolated {
                model?.importDropHover = false
                if !promised.isEmpty { model?.importPromised(promised) } else { model?.handleOpen(urls) }
            }
            return true
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            MainActor.assumeIsolated { model?.importDropHover = false }
        }
    }
}
