import AppKit

/// Editroom's alerts: the system's, with the main button (the one Return presses) white with dark text on
/// the Dark theme, as in the rest of the app, rather than in the accent grey. Other themes keep the system's.
final class EditroomAlert: NSAlert {
    @discardableResult
    override func runModal() -> NSApplication.ModalResponse {
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
        guard Theme.current == .dark, let main = buttons.first(where: { $0.keyEquivalent == "\r" }) ?? buttons.first else { return }
        main.bezelColor = .white
        if #available(macOS 26, *) { main.tintProminence = .primary }
        main.attributedTitle = NSAttributedString(string: main.title, attributes: [
            .foregroundColor: NSColor.black,
            .font: main.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        main.needsDisplay = true
    }
}
