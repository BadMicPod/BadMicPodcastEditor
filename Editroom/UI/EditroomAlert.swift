import AppKit

/// Editroom's alerts: the system's, with the main button (the one Return presses) white with dark text on
/// the Dark theme, as in the rest of the app, rather than in the accent grey. Other themes keep the system's.
final class EditroomAlert: NSAlert {
    @discardableResult
    override func runModal() -> NSApplication.ModalResponse {
        styleButtons()
        return super.runModal()
    }

    override func beginSheetModal(for sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        styleButtons()
        super.beginSheetModal(for: sheetWindow, completionHandler: handler)
    }

    private func styleButtons() {
        guard Theme.current == .dark, let main = buttons.first(where: { $0.keyEquivalent == "\r" }) ?? buttons.first else { return }
        main.bezelColor = .white
        main.attributedTitle = NSAttributedString(string: main.title, attributes: [
            .foregroundColor: NSColor.black,
            .font: main.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
    }
}
