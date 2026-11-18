import AppKit
import SwiftUI

/// Editroom > AI Agents…: whether agents can connect, who's connected, and how to connect Claude or
/// ChatGPT's Codex.
struct AgentsSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var server = MCPServer.shared
    @Environment(\.dismiss) private var dismiss

    private var binary: String { Bundle.main.executableURL?.path ?? "/Applications/Editroom.app/Contents/MacOS/Editroom" }

    private var claudeCode: String { "claude mcp add --transport http editroom \(MCPServer.endpoint)" }
    private var claudeDesktop: String {
        """
        {
          "mcpServers": {
            "editroom": {
              "command": "\(binary)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }
    private var codex: String {
        """
        [mcp_servers.editroom]
        command = "\(binary)"
        args = ["--mcp"]
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Agents")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Let Claude or ChatGPT's Codex edit here, over MCP. Each agent gets its own cursor, and every change it makes can be undone.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $server.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Theme.accent)
            }

            HStack(spacing: 8) {
                Circle().fill(server.running ? Color(hex: 0x6CC08B) : Theme.textFaint).frame(width: 7, height: 7)
                Text(server.running ? "Listening on this Mac only, at \(MCPServer.endpoint)" : server.problem ?? "Off")
                    .font(Theme.mono(11))
                    .foregroundStyle(server.running ? Theme.textDim : Theme.textFaint)
                    .textSelection(.enabled)
            }

            if !server.clients.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CONNECTED").font(Theme.label()).kerning(1.4).foregroundStyle(Theme.textFaint)
                    ForEach(server.clients.values.sorted { $0.lastSeen > $1.lastSeen }) { c in
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: MCPTools.color(for: c.name))).frame(width: 8, height: 8)
                            Text(c.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                            Text(c.lastSeen, style: .relative).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
            }

            Divider().overlay(Theme.stroke)

            SetupBlock(title: "Claude Code", note: "Run in Terminal:", code: claudeCode)
            SetupBlock(title: "Claude Desktop", note: "Add to Settings > Developer > Edit Config (claude_desktop_config.json), then restart Claude:", code: claudeDesktop)
            SetupBlock(title: "ChatGPT (Codex)", note: "Add to ~/.codex/config.toml. Works in the Codex app and Codex in the ChatGPT desktop app; ChatGPT's ordinary chat can only reach tools on the internet.", code: codex)

            HStack {
                Spacer()
                PillButton(title: "Done", prominent: true) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.panel)
    }
}

private struct SetupBlock: View {
    let title: String
    let note: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Theme.text : Theme.textDim)
            }
            Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(Theme.mono(11, .regular))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
        }
    }
}
