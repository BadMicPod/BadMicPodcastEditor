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

    private var activeID: UUID? { model.project.clientStyleID }

    private var active: ClientStyle? { store.styles.first { $0.id == activeID } }

    private var label: String {
        guard let active else { return "Client style" }
        return active.summary.isEmpty ? "\(active.name) · not trained" : "\(active.name) style"
    }

    /// Picks the client for this episode: remembered in the project, and used by Magic now.
    private func choose(_ id: UUID?) {
        store.activeID = id
        model.setClientStyle(id)
    }

    var body: some View {
        Menu {
            if let problem = store.loadProblem {
                Section("Saved styles") {
                    Button("Couldn't read saved styles…") {
                        ClientStyleDialog.say("Couldn't read saved client styles", problem)
                    }
                }
            }
            Section("Client") {
                item(name: "No client", id: nil)
                ForEach(store.styles) { style in
                    item(name: style.name, id: style.id)
                }
            }
            Divider()
            Button("New Client…") {
                ClientStyleDialog.newClient(store: store)
                choose(store.activeID)
            }
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
                Text(label)
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
        .help(active.map { $0.summary.isEmpty
                ? "\($0.name) has no style yet: add notes or train from an episode they were happy with."
                : "Magic follows \($0.name)'s style. Change it, or teach it from another episode." }
              ?? "Pick a client so Magic can follow their style, or teach it one from a finished episode.")
        .onAppear {
            // The episode decides the client: reopening a client's project brings their style back.
            let id = model.project.clientStyleID
            if let id, !store.styles.contains(where: { $0.id == id }) {
                model.setClientStyle(nil)
            }
            store.activeID = store.styles.contains { $0.id == id } ? id : nil
            // A saved file the store couldn't read: say so where it can be seen, once per run.
            if let problem = store.unshownProblem() {
                ClientStyleDialog.say("Couldn't read saved client styles", problem)
            }
        }
    }

    private func item(name: String, id: UUID?) -> some View {
        Button {
            choose(id)
        } label: {
            if activeID == id {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    // MARK: Training

    private func train() {
        guard hasEdit else { return }
        guard let learned = StyleAnalyzer.learned(for: model.project) else {
            ClientStyleDialog.say("Nothing to learn from yet",
                                  "The timeline has no picture clips, or is shorter than a second. Cut an episode first, then train from it.")
            return
        }
        ClientStyleDialog.learn(learned, from: "this episode", store: store)
        choose(store.activeID)
    }

    private func importXML() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.xml]
        if let fcpxml = UTType(filenameExtension: "fcpxml") { types.append(fcpxml) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.prompt = "Learn"
        panel.message = "Choose an edit XML (FCPXML or Premiere) from an episode you cut."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            ClientStyleDialog.say("Couldn't open that XML", "It isn't UTF-8 text, or it can't be read.")
            return
        }
        guard let learned = StyleAnalyzer.learned(fromXML: text) else {
            ClientStyleDialog.say("Couldn't learn from that XML",
                                  "No picture clips were found in \(url.lastPathComponent). Export the timeline as FCPXML or Premiere XML and try again.")
            return
        }
        ClientStyleDialog.learn(learned, from: url.lastPathComponent, store: store)
        choose(store.activeID)
    }

    private func editActive() {
        guard let active else { return }
        ClientStyleDialog.edit(active, store: store)
        choose(store.activeID)
    }

    private func deleteActive() {
        guard let active else { return }
        let alert = BadMicAlert()
        alert.messageText = "Delete \(active.name)?"
        alert.informativeText = "Magic will forget their style. Episodes already edited aren't changed."
        // Cancel first, so Return can't delete a client.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        if alert.runModal() == .alertSecondButtonReturn {
            store.remove(active.id)
            choose(nil)
        }
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
        let height: CGFloat = hasProfile ? 348 : 228
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

        accessory.label("Delivery target (optional)", y: hasProfile ? 300 : 180)
        let loudness = accessory.field(style.loudnessTarget, y: hasProfile ? 320 : 200)
        loudness.placeholderString = "-14 LUFS for YouTube, -16 for podcasts…"

        let alert = BadMicAlert()
        alert.messageText = creating ? "New client" : "\(style.name.isEmpty ? "Client" : style.name) style"
        alert.informativeText = creating
            ? (style.profile.isEmpty
                ? "Add their notes now, or train Magic from an episode once you've cut one."
                : "Their style is already learned from \(style.trainedFrom.isEmpty ? "an earlier episode" : style.trainedFrom). Add any notes too.")
            : "Their notes and what Magic learned from their episodes. Magic follows both."
        alert.accessoryView = accessory
        alert.addButton(withTitle: creating ? "Add Client" : "Save")
        alert.addButton(withTitle: "Cancel")

        // Keep what was typed if the name is empty, and ask again rather than losing the notes.
        while alert.runModal() == .alertFirstButtonReturn {
            let clean = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                alert.informativeText = "Give them a name so you can pick them again next episode."
                continue
            }
            var updated = style
            updated.name = clean
            updated.instructions = notes.string.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.loudnessTarget = loudness.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if store.styles.contains(where: { $0.id == updated.id }) {
                store.update(updated)
            } else {
                store.add(updated)
            }
            store.activeID = updated.id
            return
        }
    }

    /// Shows what was learned and offers to keep it, on the chosen client or a new one.
    static func learn(_ learned: LearnedStyle, from source: String, store: StyleStore) {
        let alert = BadMicAlert()
        alert.messageText = "Learn this style?"
        alert.informativeText = "Magic read \(source) and would follow this recipe on future episodes."
        let accessory = FlippedBox(width: 380, height: 208)
        accessory.readOnly(learned.profile, y: 0, height: 208)
        alert.accessoryView = accessory

        let active = store.active
        alert.addButton(withTitle: active.map { "Save to \($0.name)" } ?? "New Client…")
        alert.addButton(withTitle: active == nil ? "Cancel" : "New Client…")
        if active != nil { alert.addButton(withTitle: "Cancel") }
        let response = alert.runModal()

        func keep(_ style: ClientStyle) {
            var updated = style
            updated.profile = learned.profile
            updated.facts = learned.facts
            updated.trainedFrom = source
            if store.styles.contains(where: { $0.id == updated.id }) {
                store.update(updated)
            } else {
                store.add(updated)
            }
            store.activeID = updated.id
        }

        if let active, response == .alertFirstButtonReturn {
            if active.profile.isEmpty {
                keep(active)
            } else {
                let confirm = BadMicAlert()
                confirm.messageText = "Replace \(active.name)'s learned style?"
                confirm.informativeText = "The recipe from \(active.trainedFrom.isEmpty ? "their last episode" : active.trainedFrom) will be replaced. Their notes are kept."
                confirm.addButton(withTitle: "Cancel")
                confirm.addButton(withTitle: "Replace")
                if confirm.runModal() == .alertSecondButtonReturn { keep(active) }
            }
        } else if response == (active == nil ? .alertFirstButtonReturn : .alertSecondButtonReturn) {
            var style = ClientStyle(name: "")
            style.profile = learned.profile
            style.facts = learned.facts
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
