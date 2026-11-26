import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The client this episode is for, in the Magic box. Picking one makes Magic follow that client's
/// house style; training it reads a finished episode (or an edit XML) into that style.
struct ClientStyleBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var store = StyleStore.shared
    let hasEdit: Bool

    @State private var hovering = false

    private var active: ClientStyle? { store.active }

    var body: some View {
        Menu {
            Section("Client") {
                item(name: "No client", id: nil)
                ForEach(store.styles) { style in
                    item(name: style.name, id: style.id)
                }
            }
            Divider()
            Button("New Client…") { ClientStyleDialog.newClient(store: store) }
            Button("Train from This Episode…") { train() }
                .disabled(!hasEdit)
            Button("Import Edit XML…") { importXML() }
            if active != nil {
                Button("Edit \(active?.name ?? "Client")…") { editActive() }
                Button("Delete \(active?.name ?? "Client")") { deleteActive() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: active == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(active.map { "\($0.name) style" } ?? "Client style")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.65)
            }
            .foregroundStyle(active == nil ? Theme.textDim : Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.ink.opacity(hovering ? 0.12 : 0.07))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(active?.profile.isEmpty == false
              ? "Magic follows this client's style. Change it, or teach it from another episode."
              : "Pick a client so Magic can follow their style, or teach it one from a finished episode.")
    }

    private func item(name: String, id: UUID?) -> some View {
        Button {
            store.activeID = id
        } label: {
            if store.activeID == id {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    // MARK: Training

    private func train() {
        guard hasEdit else { return }
        let profile = StyleAnalyzer.profile(for: model.project)
        ClientStyleDialog.learn(profile, from: "this episode", store: store)
    }

    private func importXML() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.xml]
        panel.prompt = "Learn"
        panel.message = "Choose an edit XML (FCPXML or Premiere) from an episode you cut."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            ClientStyleDialog.say("Couldn't open that XML", "It isn't UTF-8 text, or it can't be read.")
            return
        }
        guard let profile = StyleAnalyzer.profile(fromXML: text) else {
            ClientStyleDialog.say("Couldn't learn from that XML",
                                  "No picture clips were found in \(url.lastPathComponent). Export the timeline as FCPXML or Premiere XML and try again.")
            return
        }
        ClientStyleDialog.learn(profile, from: url.lastPathComponent, store: store)
    }

    private func editActive() {
        guard let active else { return }
        ClientStyleDialog.edit(active, store: store)
    }

    private func deleteActive() {
        guard let active else { return }
        let alert = BadMicAlert()
        alert.messageText = "Delete \(active.name)?"
        alert.informativeText = "Magic will forget their style. Episodes already edited aren't changed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.remove(active.id) }
    }
}

/// The small windows behind the bar: writing a client down, and checking what was learned before
/// keeping it.
@MainActor
enum ClientStyleDialog {
    static func say(_ title: String, _ text: String) {
        let alert = BadMicAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func newClient(store: StyleStore) {
        edit(ClientStyle(name: ""), store: store, creating: true)
    }

    static func edit(_ style: ClientStyle, store: StyleStore, creating: Bool = false) {
        let hasProfile = !style.profile.isEmpty
        let height: CGFloat = hasProfile ? 292 : 196
        let accessory = FlippedBox(width: 360, height: height)

        accessory.label("Client", y: 0)
        let name = accessory.field(style.name, y: 20)
        name.placeholderString = "Their name, or the show's"
        accessory.label("How they like it edited", y: 54)
        let notes = accessory.notes(style.instructions, y: 74, height: 96)

        if hasProfile {
            accessory.label("Learned from \(style.trainedFrom.isEmpty ? "past episodes" : style.trainedFrom)", y: 180)
            accessory.readOnly(style.profile, y: 200, height: 92)
        }

        let alert = BadMicAlert()
        alert.messageText = creating ? "New client" : "\(style.name.isEmpty ? "Client" : style.name) style"
        alert.informativeText = creating
            ? "Magic will follow this client's style on every episode you cut for them."
            : "Their notes and what Magic learned from their episodes. Magic follows both."
        alert.accessoryView = accessory
        alert.addButton(withTitle: creating ? "Add Client" : "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let clean = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            say("A client needs a name", "Give them a name so you can pick them again next episode.")
            return
        }
        var updated = style
        updated.name = clean
        updated.instructions = notes.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.styles.contains(where: { $0.id == updated.id }) {
            store.update(updated)
        } else {
            store.add(updated)
        }
        store.activeID = updated.id
    }

    /// Shows what was learned and offers to keep it, on the chosen client or a new one.
    static func learn(_ profile: String, from source: String, store: StyleStore) {
        let alert = BadMicAlert()
        alert.messageText = "Learn this style?"
        alert.informativeText = "Magic read \(source) and would follow this recipe on future episodes."
        let accessory = FlippedBox(width: 380, height: 208)
        accessory.readOnly(profile, y: 0, height: 208)
        alert.accessoryView = accessory

        let active = store.active
        alert.addButton(withTitle: active.map { "Save to \($0.name)" } ?? "New Client…")
        alert.addButton(withTitle: active == nil ? "Cancel" : "New Client…")
        if active != nil { alert.addButton(withTitle: "Cancel") }
        let response = alert.runModal()

        func keep(_ style: ClientStyle) {
            var updated = style
            updated.profile = profile
            updated.trainedFrom = source
            if store.styles.contains(where: { $0.id == updated.id }) {
                store.update(updated)
            } else {
                store.add(updated)
            }
            store.activeID = updated.id
        }

        if let active, response == .alertFirstButtonReturn {
            keep(active)
        } else if response == (active == nil ? .alertFirstButtonReturn : .alertSecondButtonReturn) {
            var style = ClientStyle(name: "")
            style.profile = profile
            style.trainedFrom = source
            edit(style, store: store, creating: true)
        }
    }
}

/// An accessory view laid out from the top, so labels sit above their fields.
private final class FlippedBox: NSView {
    init(width: CGFloat, height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    func label(_ text: String, y: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: y, width: bounds.width, height: 16)
        addSubview(label)
    }

    func field(_ text: String, y: CGFloat) -> NSTextField {
        let field = NSTextField(string: text)
        field.frame = NSRect(x: 0, y: y, width: bounds.width, height: 24)
        addSubview(field)
        return field
    }

    func notes(_ text: String, y: CGFloat, height: CGFloat) -> NSTextView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: y, width: bounds.width, height: height))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: bounds.width - 4, height: height))
        view.font = .systemFont(ofSize: 12)
        view.string = text
        view.isRichText = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: bounds.width - 4, height: .greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        scroll.documentView = view
        addSubview(scroll)
        return view
    }

    func readOnly(_ text: String, y: CGFloat, height: CGFloat) {
        let view = notes(text, y: y, height: height)
        view.isEditable = false
        view.drawsBackground = false
        view.textColor = .secondaryLabelColor
    }
}
