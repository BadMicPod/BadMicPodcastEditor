import AppKit

/// BadMic Podcast Editor's alerts: the system's, with dark text on the main button (the one Return presses), which reads
/// better on its grey than white does. Its colour can't be set here: the system paints it in the accent colour,
/// which is a mid grey on the dark themes and a light one on Light (Assets › AccentColor).
final class BadMicAlert: NSAlert {
    @discardableResult
    override func runModal() -> NSApplication.ModalResponse {
        // Clicks and keys still waiting from before it opened (made while an import kept the app busy, or the
        // click that brought BadMic Podcast Editor to the front) were meant for the window behind it: let go of, rather than
        // turned away with macOS's beep once the alert is up.
        if let now = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                        subtype: 0, data1: 0, data2: 0) {
            NSApp.discardEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                           .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .keyDown, .keyUp, .scrollWheel], before: now)
        }
        styleButtons()
        // NSAlert sets its buttons up again as it opens, so they're styled once more once it's showing.
        RunLoop.main.perform(inModes: [.modalPanel, .default]) { [weak self] in self?.styleButtons() }
        return super.runModal()
    }

    override func beginSheetModal(for sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        styleButtons()
        super.beginSheetModal(for: sheetWindow, completionHandler: handler)
        DispatchQueue.main.async { [weak self] in self?.styleButtons() }
    }

    private func styleButtons() {
        guard let main = buttons.first(where: { $0.keyEquivalent == "\r" }) ?? buttons.first else { return }
        main.attributedTitle = NSAttributedString(string: main.title, attributes: [
            .foregroundColor: NSColor.black,
            .font: main.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        main.needsDisplay = true
    }
}
