import Foundation

/// A hidden copy of the project that an AI agent edits during a Magic run. Its tool calls change the
/// draft, not the timeline, so nothing moves on screen while it thinks; when it's done, its edits are
/// played on the real timeline by the Magic swarm, as one undo step.
///
/// Found by a token in the MCP address the agent is given (`/mcp?draft=…`).
@MainActor
final class MCPDraft {
    private static var open: [String: MCPDraft] = [:]

    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private(set) var base: Project
    private(set) var project: Project
    /// One entry per tool call that changed something, so history can undo a whole call.
    private(set) var steps: [[MagicEdit]] = []
    private var undone: [[MagicEdit]] = []
    var playhead = 0.0
    /// The editor it's a draft of (for the library, and rendering frames).
    private(set) weak var model: EditorModel?
    /// Tool calls so far, and the last tool called.
    private(set) var calls = 0
    private(set) var lastTool: String?

    init(project: Project) {
        base = project
        self.project = project
    }

    static func open(_ project: Project, model: EditorModel? = nil) -> MCPDraft {
        let d = MCPDraft(project: project)
        d.model = model
        open[d.token] = d
        return d
    }

    static func find(_ token: String) -> MCPDraft? { open[token] }

    func close() { Self.open[token] = nil }

    func called(_ tool: String) {
        calls += 1
        lastTool = tool
    }

    var edits: [MagicEdit] { steps.flatMap { $0 } }
    var canUndo: Bool { !steps.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    /// Something added to the library during the run (music it downloaded): in the draft, from the start.
    func addAsset(_ asset: MediaAsset) {
        guard !project.assets.contains(where: { $0.id == asset.id }) else { return }
        base.assets.append(asset)
        project.assets.append(asset)
    }

    func apply(_ edits: [MagicEdit]) {
        guard !edits.isEmpty else { return }
        for e in edits { e.apply(&project, 1) }
        steps.append(edits)
        undone.removeAll()
    }

    func undo() {
        guard let last = steps.popLast() else { return }
        undone.append(last)
        rebuild()
    }

    func redo() {
        guard let next = undone.popLast() else { return }
        steps.append(next)
        rebuild()
    }

    private func rebuild() {
        var p = base
        for e in edits { e.apply(&p, 1) }
        project = p
    }

    // MARK: Playing it back

    /// The edits in the steps a person would take. Several ripple deletes in a row each wait for the one
    /// before (each moves everything after it), so one cursor would do them one by one. A person
    /// deletes them all, then closes the gaps: so each becomes a plain delete, with its own cursor, side
    /// by side, and one "Close gaps" step after them slides the rest along to exactly where the ripple
    /// deletes would have left it.
    static func inSteps(base: Project, edits: [MagicEdit]) -> [MagicEdit] {
        var out: [MagicEdit] = []
        var p = base
        var i = 0
        while i < edits.count {
            var run: [[UUID]] = []
            var j = i
            while j < edits.count, case .remove(let ids, true) = edits[j] { run.append(ids); j += 1 }
            guard run.count >= 2 else {
                edits[i].apply(&p, 1)
                out.append(edits[i])
                i += 1
                continue
            }
            // Where everything ends up after the ripple deletes, and what's left after plain ones.
            var rippled = p
            for ids in run { rippled.remove(ids: Set(ids), ripple: true) }
            var lifted = p
            for ids in run { lifted.remove(ids: Set(ids), ripple: false) }
            let landing = Dictionary(rippled.clips.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
            let moving = lifted.clips.filter { c in landing[c.id].map { abs($0 - c.start) > 1e-9 } ?? false }
            for ids in run { out.append(.remove(ids, ripple: false)) }
            // The first clip to slide is the one it clicks on.
            if let first = moving.min(by: { ($0.start, $0.trackID.uuidString) < ($1.start, $1.trackID.uuidString) }) {
                out.append(.change(first.id, "Close gaps") { project in
                    for k in project.clips.indices {
                        if let start = landing[project.clips[k].id] { project.clips[k].start = start }
                    }
                })
            }
            p = rippled
            i = j
        }
        return out
    }

    /// The draft's edits as a Magic plan on `base`. Each edit waits for the earlier ones it depends on:
    /// ones that touched the same clips, or the same stretch of the same track. Changes to the
    /// sequence or its tracks wait for everything before and hold up everything after.
    static func plan(base: Project, edits: [MagicEdit]) -> MagicPlan {
        let edits = inSteps(base: base, edits: edits)
        struct Footprint {
            var ids: Set<UUID> = []
            var spans: [(track: UUID, from: Double, to: Double)] = []
            var barrier = false
            /// A plain delete: two of them only clash over the same clip.
            var lift = false
        }
        var p = base
        var prints: [Footprint] = []
        for e in edits {
            let before = p
            e.apply(&p, 1)
            var f = Footprint()
            if case .change(nil, _, _) = e { f.barrier = true }
            if case .remove(_, false) = e { f.lift = true }
            if before.videoTracks.map(\.id) != p.videoTracks.map(\.id) || before.audioTracks.map(\.id) != p.audioTracks.map(\.id)
                || before.width != p.width || before.height != p.height || before.fps != p.fps { f.barrier = true }
            // Every clip the edit changed, added or removed, including ones it overwrote or rippled.
            let was = Dictionary(before.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let now = Dictionary(p.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, c) in was where now[id] != c {
                f.ids.insert(id)
                f.spans.append((c.trackID, c.start, c.end))
            }
            for (id, c) in now where was[id] != c {
                f.ids.insert(id)
                f.spans.append((c.trackID, c.start, c.end))
            }
            f.ids.formUnion(e.clipIDs)
            prints.append(f)
        }
        func overlaps(_ a: Footprint, _ b: Footprint) -> Bool {
            if a.barrier || b.barrier || !a.ids.isDisjoint(with: b.ids) { return true }
            // Deleting clips side by side: one doesn't need the other gone first.
            if a.lift, b.lift { return false }
            // Touching counts: a transition needs the clip before it in place.
            for x in a.spans {
                for y in b.spans where x.track == y.track && x.from <= y.to + 1e-3 && y.from <= x.to + 1e-3 { return true }
            }
            return false
        }
        var tasks: [MagicTask] = []
        // Everything each edit waits for, directly or not.
        var ancestors: [Set<Int>] = []
        for (i, e) in edits.enumerated() {
            var after: [Int] = []
            var covered = Set<Int>()
            // Nearest first, skipping edits already waited for through another dependency.
            for j in stride(from: i - 1, through: 0, by: -1) where !covered.contains(j) && overlaps(prints[i], prints[j]) {
                after.append(j)
                covered.insert(j)
                covered.formUnion(ancestors[j])
            }
            ancestors.append(covered)
            tasks.append(MagicTask(edit: e, after: after.reversed()))
        }
        return MagicPlan(base: base, tasks: tasks)
    }
}
