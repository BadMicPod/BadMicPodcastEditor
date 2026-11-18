import AppKit
import SwiftUI

/// Editroom > Settings… (⌘,): keyboard shortcuts, and Magic (on or off, and the AI apps it can use).
struct SettingsView: View {
    @ObservedObject var model: EditorModel
    @AppStorage("settingsTab") private var tab = "shortcuts"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                SettingsTab(title: "Shortcuts", symbol: "keyboard", on: tab == "shortcuts") { tab = "shortcuts" }
                SettingsTab(title: "Magic", symbol: "wand.and.sparkles", on: tab == "magic") { tab = "magic" }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.bg))
            .frame(width: 260)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().overlay(Theme.stroke)

            if tab == "magic" {
                MagicSettings(model: model)
            } else {
                ShortcutSettings()
            }
        }
        .frame(width: 600, height: 620)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}

private struct SettingsTab: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
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
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.label()).kerning(1.4).foregroundStyle(Theme.textFaint)
    }
}

// MARK: Shortcuts

/// Listens for the next key press while a shortcut is being changed.
@MainActor
private final class ShortcutRecorder: ObservableObject {
    @Published var note: String?
    private var monitor: Any?
    private var noteTimer: Timer?

    func start(_ action: ShortcutAction) {
        stop()
        ShortcutStore.shared.recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let action = ShortcutStore.shared.recording else { return e }
                // Escape cancels.
                if let combo = KeyCombo(event: e) {
                    if let taken = ShortcutStore.shared.set(action, to: combo) {
                        self.show("\(combo.display) was \(taken.title)'s shortcut, so \(taken.title) no longer has it.")
                    }
                }
                self.stop()
                return nil
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        ShortcutStore.shared.recording = nil
    }

    private func show(_ s: String) {
        note = s
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.note = nil }
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var keys = ShortcutStore.shared
    @StateObject private var recorder = ShortcutRecorder()
    @State private var search = ""

    private func matches(_ a: ShortcutAction) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return a.title.lowercased().contains(q) || keys.combos(a).contains { $0.display.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                TextField("Search shortcuts", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                        let actions = ShortcutAction.allCases.filter { $0.group == group && matches($0) }
                        if !actions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                SectionLabel(text: group.rawValue).padding(.leading, 10)
                                VStack(spacing: 0) {
                                    ForEach(actions) { a in
                                        ShortcutRow(action: a, keys: keys, recorder: recorder)
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            Divider().overlay(Theme.stroke)
            HStack {
                Text(recorder.note ?? (keys.recording != nil ? "Press the new shortcut, or Esc to cancel." : "Click a shortcut to change it. Right-click for more."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(recorder.note != nil ? Theme.text : Theme.textDim)
                    .lineLimit(2)
                Spacer()
                PillButton(title: "Restore Defaults", prominent: false) {
                    recorder.stop()
                    keys.resetAll()
                }
                .disabled(keys.changed.isEmpty)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .onDisappear { recorder.stop() }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var keys: ShortcutStore
    @ObservedObject var recorder: ShortcutRecorder
    @State private var hovering = false

    private var recording: Bool { keys.recording == action }

    var body: some View {
        HStack(spacing: 8) {
            Text(action.title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
            if keys.isChanged(action) {
                Circle().fill(Theme.accent).frame(width: 5, height: 5).help("Changed from the default")
            }
            Spacer()
            if recording {
                Text("Press keys…")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.accent.opacity(0.25)))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.8)))
            } else if keys.combos(action).isEmpty {
                Text("None").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            } else {
                HStack(spacing: 4) {
                    ForEach(keys.combos(action), id: \.self) { KeyCap(text: $0.display) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hovering || recording ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { recording ? recorder.stop() : recorder.start(action) }
        .contextMenu {
            Button("Change Shortcut") { recorder.start(action) }
            Button("Remove Shortcut") { keys.clear(action) }
                .disabled(keys.combos(action).isEmpty)
            Button("Restore Default (\(action.defaults.map(\.display).joined(separator: ", ")))") { keys.reset(action) }
                .disabled(!keys.isChanged(action))
        }
    }
}

private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }
}

// MARK: Magic

private struct MagicSettings: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var server = MCPServer.shared
    @ObservedObject var connect = AgentConnect.shared
    @AppStorage("magicEnabled") private var magicEnabled = true

    /// Claude Code only when it's on this Mac.
    private var apps: [AgentApp] {
        [.claude, .chatgpt, .claudeCode].filter { $0 != .claudeCode || connect.states[$0] != .missing }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Magic")
                    ToggleRow(title: "Show the Magic button",
                              note: "Magic makes an edit for you: a quick cut on this Mac, or one Claude or ChatGPT works out from what you ask. Turn it off to hide the button.",
                              isOn: $magicEnabled)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "AI apps")
                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element) { i, app in
                            if i > 0 { Divider().overlay(Theme.stroke).padding(.leading, 58) }
                            AppRow(app: app, state: connect.states[app] ?? .ready, connect: connect)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                    Text("Connected apps use your own Claude or ChatGPT plan; no API key needed. Disconnecting stops Editroom answering that app, for Magic and for edits you ask for in the app.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Editing from other apps")
                    ToggleRow(title: "Let AI apps edit in Editroom",
                              note: server.enabled
                                ? "On: connected apps can edit here, with their own cursor, and every change can be undone. Only apps on this Mac can reach Editroom."
                                : "Off: no app can reach Editroom, and Magic only makes quick cuts on this Mac.",
                              isOn: $server.enabled)
                    if let problem = server.problem, server.enabled {
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xE5735C))
                    }
                    // Only agents that have done something in the last minute.
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let active = server.clients.values.filter { context.date.timeIntervalSince($0.lastSeen) < 60 }
                        if !active.isEmpty {
                            HStack(spacing: 10) {
                                Text("Working now:").font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                                ForEach(active.sorted { $0.lastSeen > $1.lastSeen }) { c in
                                    HStack(spacing: 5) {
                                        Circle().fill(Color(nsColor: MCPTools.color(for: c.name))).frame(width: 7, height: 7)
                                        Text(c.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { connect.refresh() }
        // Back from Claude or ChatGPT: see what changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connect.refresh()
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let note: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
    }
}

private struct AppRow: View {
    let app: AgentApp
    let state: AgentConnect.State
    let connect: AgentConnect

    private var icon: NSImage? {
        let id: String? = switch app {
        case .claude, .claudeCode: AgentConnect.claudeBundleID
        case .chatgpt: AgentConnect.chatgptBundleIDs.first { AgentConnect.appURL($0) != nil }
        }
        guard let id, let url = AgentConnect.appURL(id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var note: String {
        switch (app, state) {
        case (_, .missing): "Not on this Mac."
        case (_, .working): "One moment…"
        case (_, .failed(let message)): message
        case (.claude, .ready):
            connect.claudeAppOff && connect.claudeExtensionInstalled
                ? "Disconnected. To remove Editroom from Claude too, use Claude's Settings > Extensions."
                : "Adds Editroom to the Claude app as an extension."
        case (.claude, .waiting): "Click Install in the Claude app to finish."
        case (.claude, .connected): "Connected. Claude can edit here, and Magic can use it."
        case (.chatgpt, .ready): "Adds Editroom to Codex in the ChatGPT app."
        case (.chatgpt, .connected): "Connected. ChatGPT can edit here, and Magic can use it."
        case (.claudeCode, .ready): "Adds Editroom to Claude Code for all your projects."
        case (.claudeCode, .connected): "Connected. New Claude Code sessions can edit here."
        default: ""
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.raised)
                }
            }
            .frame(width: 32, height: 32)
            .opacity(state == .missing ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isFailed ? Color(hex: 0xE5735C) : Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            button
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    @ViewBuilder private var button: some View {
        switch state {
        case .missing:
            if let url = app.download {
                PillButton(title: "Get \(app.title)", prominent: false) { NSWorkspace.shared.open(url) }
            }
        case .working:
            ProgressView().controlSize(.small).frame(width: 60)
        case .waiting:
            HStack(spacing: 6) {
                PillButton(title: "Cancel", prominent: false) { connect.cancelWaiting() }
                PillButton(title: "Open Claude Again", prominent: false) { connect.reopenClaude() }
            }
        case .connected:
            PillButton(title: "Disconnect", prominent: false) { connect.disconnect(app) }
        case .ready:
            PillButton(title: "Connect", prominent: true) {
                // Connecting an app means letting AI apps in.
                if !MCPServer.shared.enabled { MCPServer.shared.enabled = true }
                connect.connect(app)
            }
        case .failed:
            PillButton(title: "Try Again", prominent: true) { connect.connect(app) }
        }
    }
}
