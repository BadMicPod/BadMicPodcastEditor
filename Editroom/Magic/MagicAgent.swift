import AppKit
import Foundation

/// Magic with an AI: Claude (through Claude Code) or ChatGPT (through Codex, which the ChatGPT app
/// ships) works out the edit in the background on a hidden draft of the project, using Editroom's
/// agent tools and the person's own Claude or ChatGPT plan. Nothing moves while it thinks; when it's
/// done, the Magic swarm plays its edits onto the timeline as one undo step.
@MainActor
final class MagicAgent: ObservableObject {
    static let shared = MagicAgent()

    enum Kind: String, CaseIterable, Identifiable {
        case claude, chatgpt
        var id: String { rawValue }
        var name: String { self == .claude ? "Claude" : "ChatGPT" }
    }

    /// What an AI said when it finished, shown under the Magic button.
    struct Note: Identifiable {
        let id = UUID()
        let agent: Kind
        let text: String
        /// It changed the timeline (so there's something to undo).
        let changed: Bool
    }

    @Published private(set) var running = false
    @Published private(set) var agent: Kind?
    /// What the AI is doing, for the Magic button.
    @Published private(set) var status: String?
    @Published var note: Note?
    /// The Magic button's "what should it make?" popover is open.
    @Published var asking = false
    /// Finished while the person was in another app: shown on the button until they come back.
    @Published private(set) var ready: String?
    private var whenBack: NSObjectProtocol?
    /// The AI picked last time, when both are on this Mac.
    @Published var preferred: Kind = Kind(rawValue: UserDefaults.standard.string(forKey: "magicAgent") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(preferred.rawValue, forKey: "magicAgent") }
    }

    private var process: Process?
    private var stopped = false
    private var pending = Data()
    private var errorText = Data()
    private var draft: MCPDraft?
    private weak var model: EditorModel?
    private var started = Date()
    /// From the AI's output: its last words, and whether it said it failed.
    private var lastMessage = ""
    private var failure: String?
    private var startedServer = false

    /// The AIs on this Mac that Magic can use.
    var available: [Kind] {
        var out: [Kind] = []
        if AgentConnect.shared.claudeCLI != nil { out.append(.claude) }
        if AgentConnect.shared.codexCLI != nil { out.append(.chatgpt) }
        return out
    }

    /// The AI to use: the one picked last time if it's still here.
    var choice: Kind? {
        let a = available
        return a.contains(preferred) ? preferred : a.first
    }

    // MARK: The brief

    static func brief(request: String, project p: Project) -> String {
        let ask = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let onTimeline = p.clips.filter { $0.kind != .audio }
        let hasEdit = !onTimeline.isEmpty
        var lines: [String] = []
        lines.append("""
        You're the editor in Editroom, the video editor open on this Mac. Use only the editroom tools, and don't stop \
        to ask anything: nobody can answer until you've finished.
        """)
        if ask.isEmpty {
            lines.append(hasEdit
                ? "They didn't ask for anything in particular: make the edit on the timeline better, the way a skilled editor would."
                : "They didn't ask for anything in particular: make the best short video you can from the library, the way a skilled editor would cut it to share.")
        } else {
            lines.append("What they asked for: \"\(ask)\"")
        }
        if hasEdit {
            lines.append(String(format: """
            The timeline already has an edit (%d clips, about %.0f seconds). Work on that edit: change it to do what they \
            asked, and keep what already works. Don't delete it and start again unless they asked for something new.
            """, onTimeline.count, p.duration))
        } else {
            lines.append("The timeline is empty: build the video from the library.")
        }
        lines.append("""
        You can only use what's in the library (list_media) and Editroom's own titles, transitions, colour and sound \
        levels. You can't add files, download anything, or make new sounds or music. If what they asked for needs \
        something the library doesn't have (sound effects, music, a logo, more footage), do the best you can \
        without it, and say what was missing at the end.

        Your edits go into a draft that the person sees all at once, played onto their timeline, when you finish. \
        So take the time to get it right; if a step goes wrong, history undoes it.

        How to work:
        1. get_project and list_media.
        2. Look at the footage with look_at_media to see what's in each shot. analyze_media finds a clip's best \
        moments, or a song's tempo and bar starts.
        3. Choose. Leave out shots that are blurry, dark, shaky, accidental, near-duplicates of a better one, or \
        screenshots. Find an order that tells something: an opening that sets the scene, a build, the best moments, \
        and a shot that feels like an ending. Prefer moments where something happens, faces and expressions, and \
        variety of framing.
        4. Cut. Shots on V1 back to back with no gaps, using source_start and duration (or trim_clip) to keep just \
        the best part of each. With music: the song on A1 from 0, cut on bar starts or beats, shorter shots where \
        the music is busy and longer where it's calm, end on a bar start, and turn the clips' own sound down to \
        about -20 dB unless someone is talking and it matters. Without music: keep the clips' sound and cut where \
        the action or sound makes a natural break. If most of the footage is vertical and the timeline is empty, \
        set_sequence to 1080 by 1920 first.
        5. To make an edit shorter or keep people watching: open on the strongest moment, cut the slow starts and \
        ends of shots, drop weak or repeated shots, and close every gap (delete_clips with ripple, or move clips).
        6. Finish. One look from list_looks on every shot so it feels like one film. A short title only if it \
        helps. Fade music out over the last 2 seconds. A dissolve or dip to black only where it helps, never on \
        every cut.
        7. Check a few moments with get_frame and fix what's wrong.

        When you're done, write one or two short sentences for the person: what you made or changed, and anything \
        you couldn't do and why. Plain words, no lists, no ids.
        """)
        return lines.joined(separator: "\n\n")
    }

    // MARK: Running

    func start(request: String, with kind: Kind, model: EditorModel) {
        guard !running, !MagicShow.isRunning else { return }
        let cli: URL? = kind == .claude ? AgentConnect.shared.claudeCLI : AgentConnect.shared.codexCLI
        guard let cli else { return }
        self.model = model
        stopped = false
        running = true
        agent = kind
        note = nil
        status = "\(kind.name) is starting"
        started = Date()
        log("MAGIC AI \(kind.rawValue) request \"\(request)\"")
        Task {
            guard await serverReady() else {
                alert("Couldn't start Magic", "Editroom couldn't open its connection for \(kind.name).")
                return done()
            }
            guard await signIn(kind, cli) else { return done() }
            guard !stopped, let endpoint = MCPServer.shared.localEndpoint else { return done() }
            let d = MCPDraft.open(model.project, model: model)
            draft = d
            status = "\(kind.name) is thinking"
            launch(kind, cli, url: "\(endpoint)?draft=\(d.token)", brief: Self.brief(request: request, project: model.project))
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        if process == nil { done() }
    }

    private func done() {
        draft?.close()
        draft = nil
        process = nil
        running = false
        status = nil
        if startedServer, !MCPServer.shared.enabled { MCPServer.shared.stop() }
        startedServer = false
    }

    /// Magic needs Editroom's connection even when other apps aren't allowed in (AI Agents off).
    private func serverReady() async -> Bool {
        let server = MCPServer.shared
        if !server.running {
            server.start()
            startedServer = true
        }
        for _ in 0..<40 where server.localEndpoint == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        return server.localEndpoint != nil
    }

    /// Signed in already, or signs in now (once, in the browser) if the person wants to.
    private func signIn(_ kind: Kind, _ cli: URL) async -> Bool {
        if await signedIn(kind, cli) { return true }
        let ask = NSAlert()
        ask.messageText = "Sign in to \(kind.name)"
        ask.informativeText = kind == .claude
            ? "Magic uses Claude through Claude Code on this Mac, with your Claude plan. It needs signing in once, in your browser."
            : "Magic uses ChatGPT through Codex, which comes with the ChatGPT app, with your ChatGPT plan. It needs signing in once, in your browser."
        ask.addButton(withTitle: "Sign In")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return false }
        status = "Signing in to \(kind.name)"
        let out = await run(cli, kind == .claude ? ["auth", "login", "--claudeai"] : ["login"])
        guard !stopped else { return false }
        if await signedIn(kind, cli) { return true }
        alert("\(kind.name) isn't signed in", out.isEmpty ? "Signing in didn't finish." : String(out.prefix(600)))
        return false
    }

    private func signedIn(_ kind: Kind, _ cli: URL) async -> Bool {
        switch kind {
        case .claude:
            let out = await run(cli, ["auth", "status", "--json"])
            guard let data = out.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["loggedIn"] as? Bool ?? false
        case .chatgpt:
            let out = await run(cli, ["login", "status"])
            return out.localizedCaseInsensitiveContains("logged in") && !out.localizedCaseInsensitiveContains("not logged in")
        }
    }

    /// Runs a program to the end (stoppable) and returns what it printed.
    private func run(_ cli: URL, _ args: [String]) async -> String {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        p.environment = Self.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return error.localizedDescription }
        process = p
        let data = await Task.detached { () -> Data in
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return d
        }.value
        if process === p { process = nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        return env
    }

    private func launch(_ kind: Kind, _ cli: URL, url: String, brief: String) {
        let fm = FileManager.default
        // An empty folder of its own, so the AI reads no project's settings or notes.
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Editroom/Magic", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = cli
        p.currentDirectoryURL = folder
        switch kind {
        case .claude:
            let config = #"{"mcpServers":{"editroom":{"type":"http","url":"\#(url)"}}}"#
            p.arguments = [
                "-p", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                "--mcp-config", config, "--strict-mcp-config",
                // Editroom's tools only: none of Claude Code's own (files, shell, web).
                "--tools", "",
                "--allowedTools", "mcp__editroom",
                "--disallowedTools", "mcp__editroom__auto_edit", "mcp__editroom__import_media", "mcp__editroom__save_project",
            ]
        case .chatgpt:
            p.arguments = [
                "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                "-s", "read-only", "-C", folder.path,
                "-c", "mcp_servers.editroom.url=\"\(url)\"",
                "-c", "mcp_servers.editroom.tool_timeout_sec=300",
                "-c", "mcp_servers.editroom.startup_timeout_sec=30",
                "-c", "approval_policy=\"never\"",
                "-",
            ]
        }
        p.environment = Self.environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors

        pending = Data()
        errorText = Data()
        lastMessage = ""
        failure = nil
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // At the end, stop listening, or this is called again and again.
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self.read(data, kind) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in self.errorText.append(data.prefix(20_000)) }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in
                // Let the last lines of output land first.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.finish(code: proc.terminationStatus)
            }
        }
        do {
            try p.run()
        } catch {
            alert("Couldn't start \(kind.name)", error.localizedDescription)
            return done()
        }
        input.fileHandleForWriting.write(Data(brief.utf8))
        try? input.fileHandleForWriting.close()
        process = p
    }

    /// The AI's progress, one JSON object a line.
    private func read(_ data: Data, _ kind: Kind) {
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch kind {
            case .claude: readClaude(json)
            case .chatgpt: readCodex(json)
            }
        }
    }

    private func readClaude(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "result":
            lastMessage = json["result"] as? String ?? lastMessage
            if (json["is_error"] as? Bool ?? false) || json["subtype"] as? String != "success" {
                failure = lastMessage.isEmpty ? "Claude stopped (\(json["subtype"] as? String ?? "error"))." : lastMessage
            }
        case "assistant":
            guard let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            if let tool = content.last(where: { $0["type"] as? String == "tool_use" })?["name"] as? String {
                toolCalled(tool.replacingOccurrences(of: "mcp__editroom__", with: ""))
            }
            if let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String, !text.isEmpty {
                lastMessage = text
            }
        default: break
        }
    }

    private func readCodex(_ json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        let item = json["item"] as? [String: Any] ?? [:]
        switch (type, item["type"] as? String) {
        case ("item.started", "mcp_tool_call"):
            toolCalled(item["tool"] as? String ?? "")
        case ("item.completed", "agent_message"):
            if let text = item["text"] as? String, !text.isEmpty { lastMessage = text }
        case ("turn.failed", _):
            failure = ((json["error"] as? [String: Any])?["message"] as? String) ?? "ChatGPT stopped."
        case ("error", _):
            failure = json["message"] as? String ?? failure
        default: break
        }
    }

    private func toolCalled(_ tool: String) {
        guard let kind = agent else { return }
        log("MAGIC AI tool \(tool)")
        status = "\(kind.name) is " + Self.doing(tool)
    }

    private static func doing(_ tool: String) -> String {
        switch tool {
        case "list_media", "get_project", "list_looks": "reading"
        case "look_at_media": "watching"
        case "analyze_media": "studying"
        case "add_clip", "trim_clip", "move_clip", "split_clip", "delete_clips", "set_sequence", "add_track": "cutting"
        case "set_grade": "grading"
        case "add_title": "titling"
        case "set_audio", "set_transition": "finishing"
        case "get_frame", "playback", "history": "checking"
        default: "thinking"
        }
    }

    private func finish(code: Int32) {
        guard running, let kind = agent else { return }
        let draft = self.draft
        let edits = draft?.edits ?? []
        let seconds = Date().timeIntervalSince(started)
        done()
        if stopped { return log("MAGIC AI stopped") }
        let stderr = String(data: errorText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log(String(format: "MAGIC AI finished code %d in %.0fs, %d tool calls, %d edits; said: %@", code, seconds,
                   draft?.calls ?? 0, edits.count, lastMessage))
        if let failure, edits.isEmpty {
            log("MAGIC AI failure: \(failure) \(stderr.suffix(400))")
            return alert("\(kind.name) couldn't make the edit", String(failure.prefix(600)))
        }
        if edits.isEmpty, code != 0 {
            log("MAGIC AI failure: exit \(code) \(stderr.suffix(400))")
            return alert("\(kind.name) couldn't make the edit", String((stderr.isEmpty ? "It stopped (code \(code))." : stderr).suffix(600)))
        }
        let said = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // Played where the person can see it: now, or when they come back to Editroom.
        guard !NSApp.isActive else { return reveal(kind, edits, said) }
        ready = "\(kind.name) is done"
        NSApp.requestUserAttention(.informationalRequest)
        whenBack = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let w = self.whenBack { NotificationCenter.default.removeObserver(w) }
                self.whenBack = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.ready = nil
                    self.reveal(kind, edits, said)
                }
            }
        }
    }

    /// Plays the AI's edits onto the timeline with the swarm, then shows what it said.
    private func reveal(_ kind: Kind, _ edits: [MagicEdit], _ said: String) {
        guard let model, !edits.isEmpty else {
            note = Note(agent: kind, text: said.isEmpty ? "\(kind.name) didn't change anything." : said, changed: false)
            return
        }
        // Played onto the timeline as it is now (in case it changed while the AI was thinking).
        let plan = MCPDraft.plan(base: model.project, edits: edits)
        log("MAGIC AI playing \(plan.tasks.count) edits")
        let shown = MagicShow.play(model: model, plan: plan) { [weak self] in
            self?.note = Note(agent: kind, text: said, changed: true)
        }
        if !shown {
            model.mutate { p in for e in edits { e.apply(&p, 1) } }
            note = Note(agent: kind, text: said, changed: true)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func log(_ s: String) {
        guard CommandLine.arguments.contains("--magic-ai") else { return }
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
