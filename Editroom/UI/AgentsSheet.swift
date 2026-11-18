import AppKit
import SwiftUI

/// Editroom > AI Agents…: connect the Claude or ChatGPT app with one click, see who's connected, and
/// what to ask.
struct AgentsSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var server = MCPServer.shared
    @ObservedObject var connect = AgentConnect.shared
    @Environment(\.dismiss) private var dismiss

    private static let prompts = [
        "Make a 30-second cut of the clips in my Editroom project, with the music, cutting on the beat.",
        "In Editroom, trim every clip to its best 3 seconds and add a title at the start.",
        "Give everything in my Editroom timeline a warm film look and fade the music out at the end.",
    ]

    /// Apps worth showing, the two Claudes together: Claude Code only when it's on this Mac.
    private var apps: [AgentApp] {
        [.claude, .claudeCode, .chatgpt].filter { $0 != .claudeCode || connect.states[$0] != .missing }
    }

    private var anyConnected: Bool { connect.states.values.contains(.connected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Agents")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Connect Claude or ChatGPT, then just tell it what you want. It edits here with its own cursor, and every change can be undone.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $server.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Theme.accent)
                    .help(server.enabled ? "Agents can connect" : "Agents can't connect")
            }

            if !server.enabled {
                Text("Turned off: connected apps can't reach Editroom until you turn this back on.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textFaint)
            } else if let problem = server.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xE5735C))
            }

            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element) { i, app in
                    if i > 0 { Divider().overlay(Theme.stroke) }
                    AppRow(app: app, state: connect.states[app] ?? .ready, connect: connect)
                }
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))

            if anyConnected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRY ASKING").font(Theme.label()).kerning(1.4).foregroundStyle(Theme.textFaint)
                    ForEach(Self.prompts, id: \.self) { PromptRow(text: $0) }
                }
            }

            // Only agents that have done something in the last minute.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let active = server.clients.values.filter { context.date.timeIntervalSince($0.lastSeen) < 60 }
                if !active.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WORKING NOW").font(Theme.label()).kerning(1.4).foregroundStyle(Theme.textFaint)
                        ForEach(active.sorted { $0.lastSeen > $1.lastSeen }) { c in
                            HStack(spacing: 8) {
                                Circle().fill(Color(nsColor: MCPTools.color(for: c.name))).frame(width: 8, height: 8)
                                Text(c.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                                Text(c.lastSeen, style: .relative).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                PillButton(title: "Done", prominent: true) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.panel)
        .onAppear { connect.refresh() }
        // Back from Claude or ChatGPT: see what changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connect.refresh()
        }
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
        case (_, .working): "Connecting…"
        case (_, .failed(let message)): message
        case (.claude, .ready): "Adds Editroom to the Claude app as an extension."
        case (.claude, .waiting): "Click Install in Claude to finish."
        case (.claude, .connected): "Connected. Ask Claude in a new chat. To remove it, use Claude's Settings > Extensions."
        case (.chatgpt, .ready): "Adds Editroom to Codex in the ChatGPT app."
        case (.chatgpt, .connected): "Connected. Quit and reopen ChatGPT, then ask Codex in a new chat."
        case (.claudeCode, .ready): "Adds Editroom to Claude Code for all your projects."
        case (.claudeCode, .connected): "Connected. Start a new Claude Code session to use it."
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
                HStack(spacing: 6) {
                    Text(app.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    if state == .connected {
                        Circle().fill(Color(hex: 0x6CC08B)).frame(width: 6, height: 6)
                    }
                }
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
            PillButton(title: "Open Again", prominent: false) { connect.connect(app) }
        case .connected:
            PillButton(title: app == .claude ? "Remove…" : "Disconnect", prominent: false) { connect.disconnect(app) }
        case .ready:
            PillButton(title: "Connect", prominent: true) { connect.connect(app) }
        case .failed:
            PillButton(title: "Try Again", prominent: true) { connect.connect(app) }
        }
    }
}

private struct PromptRow: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("“\(text)”")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(copied ? Theme.text : Theme.textDim)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
    }
}
