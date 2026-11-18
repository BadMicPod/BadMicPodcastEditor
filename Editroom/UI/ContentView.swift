import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: EditorModel
    @State private var libraryWidth: CGFloat = 252
    @State private var timelineHeight: CGFloat = 360
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            if model.viewerOnly {
                PreviewView(model: model)
            } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    LibraryView(model: model, media: model.media)
                        .frame(width: libraryWidth)
                        .background(MagicAnchor(key: "library"))
                    Splitter(vertical: true) { x in
                        libraryWidth = min(440, max(190, x - frame.minX))
                    }
                    PreviewView(model: model)
                    Hairline(vertical: true)
                    InspectorView(model: model)
                        .frame(width: InspectorView.width)
                        .background(MagicAnchor(key: "inspector"))
                }
                Splitter(vertical: false) { y in
                    timelineHeight = min(max(200, geo.size.height - 240), max(170, frame.maxY - y))
                }
                TimelinePanel(model: model)
                    .frame(height: min(timelineHeight, max(170, geo.size.height - 240)))
            }
            // A hairline under the title bar.
            .overlay(alignment: .top) { Hairline() }
            }
        }
        .background(Theme.bg)
        // Files dropped anywhere the timeline or library doesn't handle them are imported.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { model.handleOpen($0) }
            return true
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    Theme.accent.opacity(0.06)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .padding(6)
                    Text("Drop to import")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.raised))
                }
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        // The title bar in the panel black, not macOS's lighter default.
        .toolbarBackground(Theme.panel, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                    if model.isDirty {
                        Circle().fill(Theme.textFaint).frame(width: 5, height: 5)
                    }
                }
            }
            .withoutGlass()
            ToolbarItem(placement: .primaryAction) {
                ExportProgressPill(queue: model.exports)
            }
            .withoutGlass()
            ToolbarItem(placement: .primaryAction) {
                MagicButton(model: model)
                    .padding(.trailing, 8)
            }
            .withoutGlass()
            ToolbarItem(placement: .primaryAction) {
                PillButton(title: "Export", prominent: true) { model.showExport = true }
                    .help("Export (⌘E)")
                    .padding(.trailing, 10)
            }
            .withoutGlass()
        }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(model: model)
        }
        .sheet(isPresented: $model.showAgents) {
            AgentsSheet(model: model)
        }
        .alert("Import", isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importError ?? "")
        }
        .onAppear {
            KeyCommands.install(model)
            AppDelegate.shared?.model = model
        }
    }
}

/// Bare-key shortcuts (space, V, C, arrows…) that should work anywhere except while typing.
@MainActor
enum KeyCommands {
    private static var installed = false

    static func install(_ model: EditorModel) {
        guard !installed else { return }
        installed = true
        // Hand the Dock the icon directly rather than relying on its cache of this bundle path.
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.backgroundColor = Theme.NS.panel
                window.titlebarAppearsTransparent = true
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event, model) ? nil : event }
        }
    }

    private static func handle(_ e: NSEvent, _ model: EditorModel) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        // While the magic show runs, keys are handled by the show (any key skips to the end).
        if MagicShow.isRunning { return false }
        let flags = e.modifierFlags.intersection([.command, .option, .control])
        if let responder = window.firstResponder, responder is NSText {
            // Typing S, R or K goes into the text. Those keys are also View menu shortcuts, and macOS
            // checks the menu before the text field sees a key, so hand it straight to the window.
            if flags.isEmpty, let key = e.charactersIgnoringModifiers?.lowercased(), ["s", "r", "k"].contains(key) {
                window.sendEvent(e)
                return true
            }
            return false
        }
        // Only the main editor window gets bare-key shortcuts; sheets and panels keep Return/Esc for themselves.
        guard window.attachedSheet == nil, window.sheetParent == nil, !(window is NSPanel), flags.isEmpty else { return false }
        let shift = e.modifierFlags.contains(.shift)

        switch e.keyCode {
        case 49: model.togglePlay()
        case 51, 117: model.deleteSelection(ripple: shift)
        // Arrows step a frame; with ⇧ they jump to the previous or next clip start or end (or marker).
        case 123: shift ? model.jumpToEdit(forward: false) : model.step(frames: -1)
        case 124: shift ? model.jumpToEdit(forward: true) : model.step(frames: 1)
        case 126: model.jumpToEdit(forward: false)
        case 125: model.jumpToEdit(forward: true)
        case 115: model.seek(to: 0)
        case 119: model.seek(to: model.project.duration)
        case 53:
            if model.viewerOnly { model.toggleViewerFullScreen(); return true }
            model.selection = []
            model.tool = .move
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "v", "a": model.tool = .move
            case "c": model.tool = .cut
            case "s" where shift: model.audioScrub.toggle()
            case "s": model.snapping.toggle()
            case "m": model.addMarker()
            case "i": model.setInPoint()
            case "o": model.setOutPoint()
            case "x" where shift: model.clearRange()
            case "l": model.loop.toggle()
            case "f": model.toggleViewerFullScreen()
            case "r": model.sticky.toggle()
            case "k": model.skimming.toggle()
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


/// Starts the magic edit. With Claude or ChatGPT on this Mac, it asks what to make first, the AI works
/// it out in the background, and the swarm plays it onto the timeline. Without one, the swarm builds a
/// cut on its own. While the AI works, a click stops it.
struct MagicButton: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state = MagicState.shared
    @ObservedObject var ai = MagicAgent.shared
    @ObservedObject var connections = AgentConnect.shared
    @State private var hovering = false

    private var hasMedia: Bool { model.project.assets.contains { $0.kind != .audio } || !model.project.clips.isEmpty }
    private var status: String? { ai.running ? ai.status : ai.ready ?? state.status }
    /// While the AI works, hovering offers Stop in the same space (the button keeps its size, so the
    /// pointer never slips off it).
    private var offerStop: Bool { ai.running && hovering }

    var body: some View {
        Button {
            if ai.running { ai.stop() }
            else {
                connections.refresh()
                if ai.choice != nil { ai.note = nil; ai.asking = true }
                else { MagicShow.start(model: model, fromMouse: true) }
            }
        } label: {
            ZStack {
                HStack(spacing: 5) {
                    if status != nil {
                        ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "wand.and.sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(status ?? "Magic")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                }
                .opacity(offerStop ? 0 : 1)
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Stop")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                .opacity(offerStop ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.14 : 0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.05)))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: status)
        }
        .buttonStyle(.plain)
        .background(MagicAnchor(key: "magicButton"))
        .disabled(!ai.running && (!hasMedia || state.busy || MagicShow.isRunning))
        .opacity(hasMedia || ai.running ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Which AIs are connected can change in AI Agents or in the apps themselves.
        .onAppear { connections.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connections.refresh()
        }
        .help(ai.running ? "Stop \(ai.agent?.name ?? "")" : !hasMedia ? "Import some clips first"
              : ai.choice.map { "Magic: tell \($0.name) what to make" } ?? "Magic: build a cut from your media")
        // One popover: what to make, or what the AI said when it finished.
        .popover(isPresented: Binding(get: { ai.asking || ai.note != nil },
                                      set: { if !$0 { ai.asking = false; ai.note = nil } }), arrowEdge: .bottom) {
            if let note = ai.note {
                MagicNote(note: note, model: model) { ai.note = nil }
            } else {
                MagicPrompt(model: model, ai: ai) { ai.asking = false }
            }
        }
    }
}

/// What should the AI make? Typed, or picked from a few ideas. Empty makes the best cut it can.
private struct MagicPrompt: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ai: MagicAgent
    let close: () -> Void
    @State private var request = ""
    @FocusState private var focused: Bool

    private var hasEdit: Bool { model.project.clips.contains { $0.kind != .audio } }
    private var kind: MagicAgent.Kind { ai.choice ?? .claude }

    private var ideas: [String] {
        hasEdit
            ? ["Make this shorter so people keep watching", "Cut it to the beat of the music", "Give it a warm film look"]
            : ["A 30-second highlight reel cut to the music", "A calm, slow story of the day", "Fast and punchy, vertical for Reels"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(hasEdit ? "What should change?" : "What should it make?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                // Only the AIs that are connected; a choice only when there are two.
                if ai.available.count > 1 {
                    Picker("", selection: $ai.preferred) {
                        ForEach(ai.available) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            ModelMenu(ai: ai, kind: kind)

            TextField(hasEdit ? "Leave empty to make it better" : "Leave empty for the best cut", text: $request, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(3...6)
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
                .onSubmit(go)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(ideas, id: \.self) { idea in
                    Button {
                        request = idea
                        focused = true
                    } label: {
                        Text(idea)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Quick Magic, no AI") {
                    close()
                    MagicShow.start(model: model, fromMouse: false)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textFaint)
                .help("Build a cut from the library without asking an AI")
                Spacer()
                PillButton(title: "Make it with \(kind.name)", prominent: true, action: go)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Theme.panel)
        .onAppear { focused = true }
    }

    private func go() {
        close()
        ai.start(request: request, with: kind, model: model)
    }
}

/// Which model the AI uses, and how hard it thinks. Remembered for each AI.
private struct ModelMenu: View {
    @ObservedObject var ai: MagicAgent
    let kind: MagicAgent.Kind

    var body: some View {
        let current = ai.model(for: kind), effort = ai.effort(for: kind)
        let options = ai.models(for: kind)
        Menu {
            Section("Model") {
                ForEach(options) { m in
                    Button {
                        // Keep the effort if the new model has it.
                        ai.setModel(m.id, effort: m.efforts.contains(effort) ? effort : "", for: kind)
                    } label: {
                        if m.id == current { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                    }
                }
            }
            Section("Effort") {
                ForEach([""] + (options.first { $0.id == current }?.efforts ?? []), id: \.self) { e in
                    Button {
                        ai.setModel(current, effort: e, for: kind)
                    } label: {
                        let name = e.isEmpty ? "Default" : MagicAgent.effortName(e)
                        if e == effort { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        } label: {
            Text(ai.modelLabel(for: kind))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textDim)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which \(kind.name) model makes the edit, and how hard it thinks")
    }
}

/// What the AI said when it finished: what it made, and anything it couldn't do.
private struct MagicNote: View {
    let note: MagicAgent.Note
    @ObservedObject var model: EditorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: MCPTools.color(for: note.agent == .claude ? "Claude" : "ChatGPT"))).frame(width: 8, height: 8)
                Text(note.agent.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Text(note.text.isEmpty ? "Done." : note.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                if note.changed {
                    Button("Undo") {
                        close()
                        model.undo()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                }
                Spacer()
                PillButton(title: "OK", prominent: true, action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Theme.panel)
    }
}
