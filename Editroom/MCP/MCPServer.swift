import Foundation
import Network

/// Lets AI agents (Claude, ChatGPT's Codex) edit in Editroom using the Model Context Protocol.
///
/// A small HTTP server on this Mac only (127.0.0.1), speaking MCP's Streamable HTTP transport with
/// plain JSON replies. Claude Code connects to it directly; Claude Desktop and Codex start
/// `Editroom --mcp`, which passes their messages through (see MCPBridge).
@MainActor
final class MCPServer: ObservableObject {
    static let shared = MCPServer()
    nonisolated static let port: UInt16 = 47920
    nonisolated static var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    struct Client: Identifiable {
        let id: String
        var name: String
        var lastSeen: Date
    }

    @Published private(set) var running = false
    @Published private(set) var problem: String?
    @Published private(set) var clients: [String: Client] = [:]
    @Published var enabled = UserDefaults.standard.object(forKey: "agentsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "agentsEnabled")
            enabled ? start() : stop()
        }
    }

    private var listener: NWListener?
    private(set) weak var model: EditorModel?

    func attach(_ model: EditorModel) {
        self.model = model
        if enabled { start() }
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let params = NWParameters.tcp
        // This Mac only: never reachable from the network.
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: port)
            l.newConnectionHandler = { conn in
                Task { @MainActor in MCPServer.shared.accept(conn) }
            }
            l.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        MCPServer.shared.running = true
                        MCPServer.shared.problem = nil
                    case .failed(let e):
                        MCPServer.shared.running = false
                        MCPServer.shared.problem = "Couldn't listen on port \(Self.port): \(e.localizedDescription)"
                        MCPServer.shared.listener = nil
                    case .cancelled:
                        MCPServer.shared.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // MARK: HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
            Task { @MainActor in
                var buf = buffer
                if let data { buf.append(data) }
                if let request = HTTPRequest(buf) {
                    await self.respond(conn, request)
                } else if complete || error != nil || buf.count > 32 << 20 {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf)
                }
            }
        }
    }

    private func respond(_ conn: NWConnection, _ req: HTTPRequest) async {
        func send(_ status: String, _ body: Data = Data(), headers: [String: String] = [:]) {
            var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
        }
        // Only local callers by name, and no web pages: a page in a browser can't reach in.
        let host = req.headers["host"] ?? ""
        let hostName = host.split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost", "[::1]"].contains(hostName) else { return send("403 Forbidden") }
        if let origin = req.headers["origin"], !origin.isEmpty {
            guard let u = URL(string: origin), ["127.0.0.1", "localhost"].contains(u.host ?? "") else { return send("403 Forbidden") }
        }
        guard req.path.hasPrefix("/mcp") else { return send("404 Not Found") }
        switch req.method {
        case "POST": break
        case "DELETE":
            if let s = req.headers["mcp-session-id"] { clients[s] = nil }
            return send("200 OK")
        default:
            return send("405 Method Not Allowed", headers: ["Allow": "POST, DELETE"])
        }
        guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            let err = Self.error(nil, -32700, "Parse error")
            return send("400 Bad Request", (try? JSONSerialization.data(withJSONObject: err)) ?? Data(), headers: ["Content-Type": "application/json"])
        }
        var session = req.headers["mcp-session-id"]
        let method = json["method"] as? String ?? ""
        if method == "initialize" {
            session = UUID().uuidString
            let info = (json["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
            clients[session!] = Client(id: session!, name: Self.displayName(info?["name"] as? String ?? "Agent"), lastSeen: Date())
        } else if let s = session {
            if clients[s] == nil { clients[s] = Client(id: s, name: "Agent", lastSeen: Date()) }
            clients[s]?.lastSeen = Date()
        }
        // Notifications get no reply.
        guard json["id"] != nil else { return send("202 Accepted") }
        let reply = await MCPHandler.handle(json, client: session.flatMap { clients[$0] })
        let body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        var headers = ["Content-Type": "application/json"]
        if let session { headers["Mcp-Session-Id"] = session }
        send("200 OK", body, headers: headers)
    }

    /// What to call an agent on its cursor.
    static func displayName(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("claude") { return "Claude" }
        if s.contains("codex") { return "Codex" }
        if s.contains("chatgpt") || s.contains("openai") { return "ChatGPT" }
        let words = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}

/// Just enough HTTP/1.1 to read one request with a body.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Nil until the whole request (headers and body) has arrived.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        method = String(parts[0])
        path = String(parts[1])
        headers = h
        body = data[bodyStart..<(bodyStart + length)]
    }
}

/// JSON-RPC methods: the MCP handshake, listing tools and calling them.
@MainActor
enum MCPHandler {
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func handle(_ req: [String: Any], client: MCPServer.Client?) async -> [String: Any] {
        let id = req["id"]
        let params = req["params"] as? [String: Any] ?? [:]
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result] }
        switch req["method"] as? String ?? "" {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? versions[0]
            return ok([
                "protocolVersion": versions.contains(asked) ? asked : versions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "editroom", "title": "Editroom", "version": "1.0"],
                "instructions": MCPTools.instructions,
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": MCPTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let model = MCPServer.shared.model else {
                return ok(MCPTools.failure("Editroom isn't ready yet."))
            }
            do {
                let content = try await MCPTools.call(name, args, model: model, client: client)
                return ok(["content": content, "isError": false])
            } catch {
                return ok(MCPTools.failure((error as? MCPToolError)?.message ?? error.localizedDescription))
            }
        default:
            return MCPServer.error(id, -32601, "Method not found")
        }
    }
}
