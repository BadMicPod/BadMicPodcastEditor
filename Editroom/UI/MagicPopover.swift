import AppKit
import SwiftUI

/// The Magic button's popover. A switch (like the timeline's select and cut tools) picks Claude,
/// ChatGPT or Local. An AI that's ready shows the prompt; one that isn't walks through connecting it
/// right here. Disconnecting lives in AI Agents.
struct MagicPopover: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ai: MagicAgent
    @ObservedObject var connections = AgentConnect.shared
    @ObservedObject var server = MCPServer.shared
    let close: () -> Void

    @State private var request = ""
    /// Just connected from here: a moment to say so before the prompt.
    @State private var justConnected: MagicAgent.Kind?
    /// Connecting started from here (so finishing it shows "connected").
    @State private var connecting: MagicAgent.Kind?

    private var hasEdit: Bool { model.project.clips.contains { $0.kind != .audio } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AITabs(selection: $ai.tab)
            content
                .padding(.top, 12)
            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.panel)
        .onAppear { connections.refresh() }
        .onChange(of: ai.available) { _, now in
            if let k = connecting, now.contains(k) {
                justConnected = k
                connecting = nil
            }
        }
    }

    // MARK: What the tab shows

    @ViewBuilder private var content: some View {
        if let kind = ai.tab.kind {
            if justConnected == kind {
                Centered(logo: AppLogo(kind: kind, size: 36), title: "\(kind.name) is connected",
                         text: kind == .claude ? "Tell it what to make. You can disconnect any time in AI Agents."
                                               : "Tell it what to make. To edit from the ChatGPT app as well, quit and reopen it once.") {
                    PillButton(title: "Continue", prominent: true) { justConnected = nil }
                }
            } else if !ai.installed(kind) {
                Centered(logo: AppLogo(kind: kind, size: 36), title: "Get the \(kind.name) app",
                         text: kind == .claude ? "Claude edits for you through the Claude app on this Mac. Install it, then come back to connect."
                                               : "ChatGPT edits for you through Codex in the ChatGPT app on this Mac. Install it, then come back to connect.") {
                    PillButton(title: "Download \(kind.name)", prominent: true) {
                        if let url = (kind == .claude ? AgentApp.claude : AgentApp.chatgpt).download { NSWorkspace.shared.open(url) }
                    }
                }
            } else if kind == .claude, connections.states[.claude] == .waiting {
                Centered(logo: AppLogo(kind: kind, size: 36), title: "Finish in the Claude app",
                         text: "Claude is asking whether to add Editroom. Click Install there and this updates by itself.") {
                    HStack(spacing: 8) {
                        PillButton(title: "Cancel", prominent: false) {
                            connecting = nil
                            connections.cancelWaiting()
                        }
                        PillButton(title: "Open Claude again", prominent: false) { connections.reopenClaude() }
                    }
                }
            } else if !ai.connected(kind) {
                Centered(logo: AppLogo(kind: kind, size: 36), title: "Connect \(kind.name)",
                         text: kind == .claude ? "Let Claude edit for you, with your Claude plan. Nothing is shared until you ask it to make an edit."
                                               : "Let ChatGPT edit for you, with your ChatGPT plan. It works through Codex in the ChatGPT app.") {
                    PillButton(title: "Connect \(kind.name)", prominent: true) { connect(kind) }
                }
                if case .failed(let why) = connections.states[app(for: kind)] {
                    Text(why).font(.system(size: 11)).foregroundStyle(Color(hex: 0xE5735C)).frame(maxWidth: .infinity).padding(.top, 6)
                }
            } else if !ai.runnable(kind) {
                // Connected for use from the Claude app, but Magic runs Claude Code, which the Claude
                // app installs the first time its Code tab is opened.
                Centered(logo: AppLogo(kind: kind, size: 36), title: "Open Claude Code once",
                         text: "Magic uses Claude Code, which comes with the Claude app. Open the Claude app's Code tab once, then come back.") {
                    PillButton(title: "Open Claude", prominent: true) {
                        if let url = AgentConnect.appURL(AgentConnect.claudeBundleID) {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            } else {
                PromptForm(model: model, ai: ai, kind: kind, request: $request, hasEdit: hasEdit,
                           manage: { close(); model.showAgents = true }) { go(kind) }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quick cut on this Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Finds the best moments, cuts to the beat of your music, titles and grades it. A few seconds, no AI, nothing leaves your Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    PillButton(title: "Make it", prominent: true) {
                        close()
                        MagicShow.start(model: model, fromMouse: false)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
        }
    }

    /// Whose plan it uses on the left; AI Agents settings on the right.
    private var footer: some View {
        HStack {
            Text(footerText)
            Spacer()
            if ai.tab != .local {
                Button("Manage AI Agents") {
                    close()
                    model.showAgents = true
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textFaint)
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
        .padding(.top, 11)
    }

    private var footerText: String {
        guard let kind = ai.tab.kind else { return "On this Mac" }
        if !ai.installed(kind) { return "Free to download" }
        if kind == .claude, connections.states[.claude] == .waiting { return "Waiting for Claude…" }
        if !ai.connected(kind) { return "No API key needed" }
        return "Uses your \(kind.name) plan"
    }

    // MARK: Actions

    private func app(for kind: MagicAgent.Kind) -> AgentApp {
        switch kind {
        case .chatgpt: .chatgpt
        // The Claude app's extension; Claude Code when there's no Claude app.
        case .claude: AgentConnect.appURL(AgentConnect.claudeBundleID) != nil ? .claude : .claudeCode
        }
    }

    private func connect(_ kind: MagicAgent.Kind) {
        connecting = kind
        // Connecting an AI here means letting AI apps in.
        if !server.enabled { server.enabled = true }
        let app = app(for: kind)
        if connections.states[app] == .connected {
            connections.refresh()
            justConnected = kind
            connecting = nil
        } else {
            connections.connect(app)
        }
    }

    private func go(_ kind: MagicAgent.Kind) {
        close()
        ai.start(request: request, with: kind, model: model)
        request = ""
    }
}

// MARK: Pieces

/// Claude, ChatGPT or Local, in the style of the timeline's select and cut switch.
private struct AITabs: View {
    @Binding var selection: MagicAgent.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MagicAgent.Tab.allCases) { tab in
                AITab(tab: tab, on: selection == tab) { selection = tab }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.bg))
    }
}

private struct AITab: View {
    let tab: MagicAgent.Tab
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let kind = tab.kind {
                    AppLogo(kind: kind, size: 15).opacity(on ? 1 : 0.8)
                } else {
                    Image(systemName: "laptopcomputer").font(.system(size: 11, weight: .semibold))
                }
                Text(tab.name).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(on || hovering ? Theme.text : Theme.textDim)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(on ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// An AI's own app icon, from the app on this Mac.
struct AppLogo: View {
    let kind: MagicAgent.Kind
    let size: CGFloat

    private var icon: NSImage? {
        let ids = kind == .claude ? [AgentConnect.claudeBundleID] : AgentConnect.chatgptBundleIDs
        guard let url = ids.lazy.compactMap(AgentConnect.appURL).first else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(kind == .claude ? Color(hex: 0xD97757) : Color(hex: 0xF2F2F0))
                .frame(width: size, height: size)
                .overlay(Image(systemName: kind == .claude ? "asterisk" : "circle.dashed")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(kind == .claude ? .white : .black))
        }
    }
}

/// A centred step: logo, title, a line or two, and its buttons.
private struct Centered<Buttons: View>: View {
    let logo: AppLogo
    let title: String
    let text: String
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 0) {
            logo.padding(.bottom, 9)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            buttons()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// What should the AI make? Typed, or picked from a few ideas. Empty makes the best cut it can.
private struct PromptForm: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ai: MagicAgent
    let kind: MagicAgent.Kind
    @Binding var request: String
    let hasEdit: Bool
    let manage: () -> Void
    let go: () -> Void
    @FocusState private var focused: Bool
    /// A height the person dragged the box to (0: not set), kept for next time.
    @AppStorage("magicPromptHeight") private var setHeight: Double = 0
    @State private var fieldHeight: Double = 0
    @State private var dragFrom: Double?

    /// Three lines to start; it grows as you type, up to three times that, then scrolls.
    private static let baseHeight = 66.0
    private static let maxHeight = baseHeight * 3

    /// A name for the menu, and the prompt it fills the box with (to send as it is, or change first).
    private typealias Idea = (name: String, symbol: String, prompt: String)

    private static let make: [Idea] = [
        ("Story", "book",
         "Make the best story you can from this footage: a clear beginning, middle and end, the strongest moments where they land hardest, and shots left to breathe where it matters."),
        ("Highlight reel", "sparkles",
         "Make a 30 to 60 second highlight reel of the best moments, cut to the beat of the music, opening on the strongest shot and ending on a bar."),
        ("Timelapse", "timer",
         "Make a timelapse over the music: speed the footage up, cut out the dead space where nothing changes, keep the moments where something happens, and end on the strongest shot."),
        ("Vlog", "person.wave.2",
         "Make an engaging vlog, up to 8 minutes: hook in the first few seconds, keep the parts where someone is talking or something happens, cut pauses, retakes and repeats, and add short titles to mark each part."),
        ("Vertical reel", "iphone",
         "Make a fast, punchy 15 to 30 second vertical video for Reels and TikTok: 1080 by 1920, a hook in the first second, quick cuts on the beat."),
    ]

    private static let improve: [Idea] = [
        ("Tighten it", "scissors",
         "Make this shorter so people keep watching: open on the strongest moment, cut the slow starts and ends of shots, and drop weak or repeated shots."),
        ("Cut to the beat", "metronome",
         "Recut this to the beat of the music: cuts on beats, the biggest moments on bar starts, and end on a bar."),
        ("Smooth it out", "wind",
         "Smooth this out: fix jumpy cuts, add a dissolve only where the scene changes, even out the sound, and fade in and out."),
        ("One look", "camera.filters",
         "Give it one consistent look: the same warm film grade on every shot, matched in brightness so it feels like one film."),
    ]

    private static let sound: [Idea] = [
        ("Find music", "magnifyingglass",
         "Find music that suits this video and add it to the timeline. Make sure the music is royalty free and does not require attribution."),
        ("Music and levels", "music.note",
         "Pick the best music in my Media for this edit, cut so the music and pictures land together, keep voices clear over it, and fade in and out."),
    ]

    private var placeholder: String {
        hasEdit
            ? "Describe what to change, or leave this empty and \(kind.name) will make the best video it can from your Media."
            : "Describe the video you want, or leave this empty and \(kind.name) will make the best video it can from the clips and music in your Media."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hasEdit ? "What should change?" : "What should it make?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                // Ideas fill the box, to send as they are or change first.
                Menu {
                    if hasEdit {
                        Section("Improve") {
                            ForEach(Self.improve, id: \.name) { idea in
                                Button { use(idea.prompt) } label: { Label(idea.name, systemImage: idea.symbol) }
                            }
                        }
                    }
                    Section("Create") {
                        ForEach(Self.make, id: \.name) { idea in
                            Button { use(idea.prompt) } label: { Label(idea.name, systemImage: idea.symbol) }
                        }
                    }
                    Section("Sound") {
                        ForEach(Self.sound, id: \.name) { idea in
                            Button { use(idea.prompt) } label: { Label(idea.name, systemImage: idea.symbol) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb").font(.system(size: 10, weight: .semibold))
                        Text("Ideas").font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                    }
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Ideas to start from")
            }
            .padding(.bottom, 8)
            TextField(placeholder, text: $request, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .lineLimit(3...11)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, 14)
                .frame(minHeight: max(Self.baseHeight, setHeight), maxHeight: Self.maxHeight, alignment: .topLeading)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { fieldHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in fieldHeight = h }
                })
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
                .overlay(alignment: .bottomTrailing) {
                    ResizeGrip()
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let from = dragFrom ?? fieldHeight
                                dragFrom = from
                                setHeight = min(Self.maxHeight, max(Self.baseHeight, from + v.translation.height))
                            }
                            .onEnded { _ in dragFrom = nil })
                        .onTapGesture(count: 2) { setHeight = 0 }
                        .help("Drag to make the box taller or shorter; double-click to reset")
                }
                .onSubmit(go)
                .padding(.bottom, 11)
            HStack(spacing: 5) {
                ModelChip(ai: ai, kind: kind, manage: manage)
                EffortChip(ai: ai, kind: kind)
                Spacer()
                PillButton(title: "Make it", prominent: true, action: go)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { focused = true }
    }

    private func use(_ idea: String) {
        request = idea
        focused = true
    }
}

/// The corner grip for resizing the prompt box, with the up-down cursor.
private struct ResizeGrip: View {
    @State private var hovering = false

    var body: some View {
        Canvas { ctx, size in
            for i in 0..<2 {
                let inset = CGFloat(i) * 4
                var p = Path()
                p.move(to: CGPoint(x: size.width - 3, y: 3 + inset))
                p.addLine(to: CGPoint(x: 3 + inset, y: size.height - 3))
                ctx.stroke(p, with: .color(Color.white.opacity(hovering ? 0.5 : 0.25)), lineWidth: 1.2)
            }
        }
        .frame(width: 12, height: 12)
        .padding(4)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }
}

/// A small rounded chip that opens a menu.
private struct ChipLabel: View {
    var symbol: String?
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(title).font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(Color(hex: 0xC9C9C5))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .contentShape(Capsule())
    }
}

private struct ModelChip: View {
    @ObservedObject var ai: MagicAgent
    let kind: MagicAgent.Kind
    let manage: () -> Void

    var body: some View {
        let options = ai.models(for: kind)
        Menu {
            Picker("Model", selection: Binding(
                get: { ai.model(for: kind) },
                set: { id in
                    // Keep the effort if the new model has it.
                    let e = ai.effort(for: kind)
                    let option = options.first { $0.id == id }
                    ai.setModel(id, effort: option?.efforts.contains(e) == true ? e : option?.defaultEffort ?? e, for: kind)
                })) {
                ForEach(options) { m in
                    Text(m.name).badge(m.blurb.isEmpty ? nil : Text(m.blurb)).tag(m.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(title: ai.modelName(for: kind))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which \(kind.name) model makes the edit")
    }
}

private struct EffortChip: View {
    @ObservedObject var ai: MagicAgent
    let kind: MagicAgent.Kind

    var body: some View {
        let efforts = ai.models(for: kind).first { $0.id == ai.model(for: kind) }?.efforts ?? []
        Menu {
            Picker("Effort", selection: Binding(
                get: { ai.effort(for: kind) },
                set: { ai.setModel(ai.model(for: kind), effort: $0, for: kind) })) {
                ForEach(efforts, id: \.self) { e in
                    let blurb = MagicAgent.effortBlurb(e)
                    Text(MagicAgent.effortName(e)).badge(blurb.isEmpty ? nil : Text(blurb)).tag(e)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(symbol: "gauge.with.dots.needle.33percent", title: MagicAgent.effortName(ai.effort(for: kind)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How hard \(kind.name) thinks: higher is slower and uses more of your plan")
    }
}

/// What the AI said when it finished: what it made, and anything it couldn't do.
struct MagicNoteView: View {
    let note: MagicAgent.Note
    @ObservedObject var model: EditorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                AppLogo(kind: note.agent, size: 18)
                Text(note.agent.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                if !note.detail.isEmpty {
                    Text(note.detail).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
            // AIs write links in Markdown ([CC0](https://…)): shown as links you can click.
            Text((try? AttributedString(markdown: note.text.isEmpty ? "Done." : note.text,
                                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(note.text))
                .tint(Color(hex: 0x8AB4FF))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                if note.changed {
                    PillButton(title: "Undo", prominent: false) {
                        close()
                        model.undo()
                    }
                }
                Spacer()
                PillButton(title: "Done", prominent: true, action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.panel)
    }
}
