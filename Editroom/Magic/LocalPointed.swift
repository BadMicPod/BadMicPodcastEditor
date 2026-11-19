import Foundation

/// Local's edits on what someone points at: the selected clips (`@selected`, "this clip"), the
/// playhead (`@playhead`) or the in/out range (`@in-out`). Each is a small, direct edit: take it out,
/// speed it up or slow it down, a look, split or end there. Anything else is said plainly, not guessed.
@MainActor
enum LocalPointed {
    struct Outcome {
        /// Nil when there's nothing it can do; `said` says why.
        var plan: MagicPlan?
        var said: String
    }

    /// Nil when the request doesn't point at anything: then Local makes its usual whole-edit changes.
    static func plan(request: String, recipe: LocalRecipe, pointers ptr: MagicPointers, project p: Project) -> Outcome? {
        let mentions = Set(MagicMention.find(in: request, media: p.assets).map(\.mention))
        let text = request.lowercased()
        func says(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        let selection = mentions.contains(.selected) || (!ptr.selected.isEmpty && says([
            "selected", "selection", "this clip", "this shot", "these clips", "these shots", "that clip", "that shot", "those clips", "those shots",
        ]))
        let range = mentions.contains(.range) || says(["in/out", "in-out", "in and out points", "marked range", "the range"])
        let playhead = mentions.contains(.playhead) || says(["playhead"])
        if let moved = reorder(request: request, project: p) { return moved }
        guard selection || range || playhead else { return nil }

        let remove = says(["remove", "delete", "take out", "take it out", "take them out", "get rid", "cut out", "cut it", "cut them", "drop",
                           "no good", "not good", "bad", "don't like", "dont like", "hate", "useless", "lose ", "kill"])
        let speed = recipe.speed
        let look = recipe.look
        var edits: [MagicEdit] = []
        func visual(_ c: Clip) -> Bool { c.kind == .video || c.kind == .image }
        func lookEdits(_ ids: [UUID], in q: Project) -> [MagicEdit] {
            guard let look else { return [] }
            return q.clips.filter { ids.contains($0.id) && visual($0) }.compactMap { c in
                if look == "none" {
                    guard c.grade?.look != nil else { return nil }
                    return .change(c.id, "No look") { q in
                        if let i = q.index(of: c.id) { var g = q.clips[i].grade ?? ColorGrade(); g.look = nil; q.clips[i].grade = g }
                    }
                }
                return c.grade?.look == look ? nil : .look(c.id, name: look)
            }
        }
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let cant = "For anything more, use Claude or ChatGPT."

        // The selected clips.
        if selection {
            let chosen = ptr.selected.compactMap { id in p.clips.first { $0.id == id } }
            guard !chosen.isEmpty else { return Outcome(said: "Nothing was selected. Select clips on the timeline first, then ask again.") }
            let ids = p.unlocked(p.linked(Set(chosen.map(\.id))))
            guard !ids.isEmpty else { return Outcome(said: "The selected clips are on locked tracks, so nothing was changed.") }
            let n = chosen.filter { ids.contains($0.id) && $0.kind != .audio }.count
            let what = plural(max(n, 1), "selected clip")
            if remove, speed == nil, look == nil {
                edits.append(.remove(Array(ids), ripple: true))
                return Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: "Took out the \(what) and closed the gap.")
            }
            var parts: [String] = []
            if let speed {
                edits.append(.change(chosen.first!.id, String(format: "Speed ×%g", speed)) { q in q.setSpeed(ids: ids, speed: speed) })
                parts.append(String(format: "set the %@ to %g%% speed", what, speed * 100))
            }
            let looks = lookEdits(Array(ids), in: p)
            edits += looks
            if let look, !looks.isEmpty { parts.append(look == "none" ? "took the look off" : "gave \(speed == nil ? "the \(what)" : "them") the \(look) look") }
            guard !edits.isEmpty else {
                if look != nil { return Outcome(said: "The \(what) already \(look == "none" ? "have no look" : "have the \(look!) look").") }
                return Outcome(said: "Local can take out, speed up, slow down or give a look to the selected clips. \(cant)")
            }
            return Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: parts.joined(separator: " and ").capitalizedFirst + ".")
        }

        // The in/out range.
        if range {
            guard let r = ptr.range else { return Outcome(said: "There's no in/out range set. Mark one with I and O, then ask again.") }
            let span = String(format: "%.1fs to %.1fs", r.start, r.end)
            let all = p.unlocked(Set(p.clips.map(\.id)))
            if says(["only", "keep ", "just "]), !says(["remove", "delete", "take out", "get rid", "cut out"]) {
                edits.append(.change(nil, "Keep range") { q in q = q.cropped(to: r) })
                return Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: "Kept just \(span) and took out the rest.")
            }
            if remove, speed == nil, look == nil {
                edits.append(.change(nil, "Remove range") { q in
                    let ids = q.unlocked(Set(q.clips.map(\.id)))
                    _ = q.split(ids: ids, at: r.start)
                    _ = q.split(ids: q.unlocked(Set(q.clips.map(\.id))), at: r.end)
                    let inside = q.clips.filter { $0.start >= r.start - 1e-6 && $0.end <= r.end + 1e-6 && !q.isLocked($0.trackID) }.map(\.id)
                    q.clips.removeAll { inside.contains($0.id) }
                    for i in q.clips.indices where q.clips[i].start >= r.end - 1e-6 && !q.isLocked(q.clips[i].trackID) {
                        q.clips[i].start -= r.end - r.start
                    }
                    q.inPoint = nil
                    q.outPoint = nil
                })
                return Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: "Took out \(span) and closed the gap.")
            }
            if speed != nil || look != nil {
                // Cut at the range's edges, then change just what's inside.
                var q = p
                _ = q.split(ids: all, at: r.start)
                _ = q.split(ids: q.unlocked(Set(q.clips.map(\.id))), at: r.end)
                let inside = q.clips.filter { $0.start >= r.start - 1e-6 && $0.end <= r.end + 1e-6 && !q.isLocked($0.trackID) }.map(\.id)
                edits.append(.change(nil, "Cut at range") { x in
                    _ = x.split(ids: x.unlocked(Set(x.clips.map(\.id))), at: r.start)
                    _ = x.split(ids: x.unlocked(Set(x.clips.map(\.id))), at: r.end)
                })
                var parts: [String] = []
                if let speed {
                    edits.append(.change(nil, String(format: "Speed ×%g", speed)) { x in
                        let ids = Set(x.clips.filter { $0.start >= r.start - 1e-6 && $0.end <= r.end + 1e-6 && !x.isLocked($0.trackID) }.map(\.id))
                        x.setSpeed(ids: ids, speed: speed)
                    })
                    parts.append(String(format: "set %@ to %g%% speed", span, speed * 100))
                }
                let looks = lookEdits(inside, in: q)
                // The clips the looks go on only exist once the range is cut, with new ids: by time instead.
                if let look, !looks.isEmpty {
                    edits.append(.change(nil, look == "none" ? "No look" : look) { x in
                        for i in x.clips.indices where x.clips[i].start >= r.start - 1e-6 && x.clips[i].end <= r.end + 1e-6
                            && !x.isLocked(x.clips[i].trackID) && (x.clips[i].kind == .video || x.clips[i].kind == .image) {
                            var g = x.clips[i].grade ?? ColorGrade()
                            g.look = look == "none" ? nil : look
                            x.clips[i].grade = g
                        }
                    })
                    parts.append(look == "none" ? "took the look off \(span)" : "gave \(span) the \(look) look")
                }
                if parts.isEmpty { return Outcome(said: "\(span) already looks like that.") }
                return Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: parts.joined(separator: " and ").capitalizedFirst + ".")
            }
            return Outcome(said: "Local can take out, keep only, speed up, slow down or give a look to the in/out range. \(cant)")
        }

        // The playhead.
        let t = ptr.playhead
        let at = String(format: "%.1fs", t)
        let all = p.unlocked(Set(p.clips.map(\.id)))
        if says(["after", "end here", "end at", "end it", "ends at", "ends here", "stop at", "stop here", "finish", "rest of"]) {
            guard p.clips.contains(where: { all.contains($0.id) && $0.end > t + 1e-3 }) else { return Outcome(said: "Nothing comes after the playhead.") }
            edits.append(.change(nil, "End here") { q in
                _ = q.split(ids: q.unlocked(Set(q.clips.map(\.id))), at: t)
                let locked = Set(q.clips.map(\.trackID).filter { q.isLocked($0) })
                q.clips.removeAll { $0.start >= t - 1e-6 && !locked.contains($0.trackID) }
            })
            return Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: "Ended it at \(at), taking out everything after.")
        }
        if says(["before", "start here", "start at", "start it", "starts at", "starts here", "begin", "open at", "open here"]) {
            guard t > 1e-3 else { return Outcome(said: "The playhead is at the start, so there's nothing before it.") }
            edits.append(.change(nil, "Start here") { q in
                _ = q.split(ids: q.unlocked(Set(q.clips.map(\.id))), at: t)
                let locked = Set(q.clips.map(\.trackID).filter { q.isLocked($0) })
                q.clips.removeAll { $0.end <= t + 1e-6 && !locked.contains($0.trackID) }
                for i in q.clips.indices where !q.isLocked(q.clips[i].trackID) { q.clips[i].start = max(0, q.clips[i].start - t) }
            })
            return Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: "Started it at \(at), taking out everything before.")
        }
        if says(["split", "cut", "blade", "slice"]) {
            let under = p.clips.filter { all.contains($0.id) && $0.start < t - 1e-3 && $0.end > t + 1e-3 }
            guard !under.isEmpty else { return Outcome(said: "There's no clip under the playhead to split.") }
            edits.append(.change(under.first!.id, "Split") { q in _ = q.split(ids: Set(under.map(\.id)), at: t) })
            return Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: "Split \(plural(under.count, "clip")) at \(at).")
        }
        return Outcome(said: "At the playhead, Local can split the clips there, or end or start the video there. \(cant)")
    }
}

extension LocalPointed {
    /// Moving shots around the edit by name: "put @b in front of @a", "swap @a and @b", "move @a to the
    /// end", "open on @a". The shots on the main picture track are put in the new order, back to back,
    /// each with its own sound; nothing else changes.
    static func reorder(request: String, project p: Project) -> Outcome? {
        let text = request.lowercased()
        func says(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        // The files it names, in the order it names them: with @, or by name.
        var named: [(at: Int, id: UUID)] = MagicMention.find(in: request, media: p.assets).compactMap { m in
            if case .media(let id) = m.mention { return (m.range.location, id) } else { return nil }
        }
        let plain = request as NSString
        for a in LocalBrain.named(in: request, media: p.assets) where !named.contains(where: { $0.id == a.id }) {
            let bare = (a.name as NSString).deletingPathExtension
            let r = plain.range(of: bare, options: .caseInsensitive)
            if r.location != NSNotFound { named.append((r.location, a.id)) }
        }
        named.sort { $0.at < $1.at }
        let ids = named.map(\.id)
        guard !ids.isEmpty else { return nil }

        enum Move { case swap, before, after, start, end }
        let move: Move? =
            ids.count >= 2 && says(["swap", "switch", "trade places", "flip"]) ? .swap
            : ids.count >= 2 && says(["in front of", "infront of", "before", "ahead of", "earlier than"]) ? .before
            : ids.count >= 2 && says(["after", "behind", "following", "later than"]) ? .after
            : says(["to the start", "to the beginning", "to the front", "at the start", "at the beginning", "open on", "open with",
                    "start with", "start on", "begin with", "first shot", "go first", "come first"]) ? .start
            : says(["to the end", "at the end", "end on", "end with", "close on", "close with", "last shot", "go last", "come last"]) ? .end
            : nil
        guard let move else { return nil }

        // The main picture track: the lowest video track with shots on it.
        // No edit yet ("open on @intro" for a new cut): that's for the planner that makes the cut.
        guard let track = p.videoTracks.first(where: { t in p.clips.contains { $0.trackID == t.id && ($0.kind == .video || $0.kind == .image) } }) else {
            return nil
        }
        guard !p.isLocked(track.id) else { return Outcome(said: "The main video track is locked, so nothing was moved.") }
        let shots = p.clips.filter { $0.trackID == track.id && ($0.kind == .video || $0.kind == .image) }.sorted { $0.start < $1.start }
        func name(_ id: UUID) -> String { p.assets.first { $0.id == id }?.name ?? "that file" }
        func shot(_ id: UUID) -> Clip? { shots.first { $0.assetID == id } }
        guard let a = shot(ids[0]) else { return Outcome(said: "\(name(ids[0])) isn't in the edit, so there's nothing to move.") }
        var order = shots
        let said: String
        switch move {
        case .swap, .before, .after:
            guard let b = shot(ids[1]), b.id != a.id else { return Outcome(said: "\(name(ids[1])) isn't in the edit, so there's nothing to move it next to.") }
            if move == .swap {
                let i = order.firstIndex { $0.id == a.id }!, j = order.firstIndex { $0.id == b.id }!
                order.swapAt(i, j)
                said = "Swapped \(name(ids[0])) and \(name(ids[1]))."
            } else {
                order.removeAll { $0.id == a.id }
                let j = order.firstIndex { $0.id == b.id }!
                order.insert(a, at: move == .before ? j : j + 1)
                said = "Put \(name(ids[0])) \(move == .before ? "in front of" : "after") \(name(ids[1]))."
            }
        case .start:
            order.removeAll { $0.id == a.id }
            order.insert(a, at: 0)
            said = "Moved \(name(ids[0])) to the start."
        case .end:
            order.removeAll { $0.id == a.id }
            order.append(a)
            said = "Moved \(name(ids[0])) to the end."
        }
        guard order.map(\.id) != shots.map(\.id) else { return Outcome(said: "\(said.dropLast()) — it was already there, so nothing changed.") }
        // Back to back from where the edit starts, each shot taking its own sound with it.
        var t = shots[0].start
        var deltas: [UUID: Double] = [:]
        for c in order {
            deltas[c.id] = t - c.start
            t += c.duration
        }
        let edit = MagicEdit.change(a.id, "Move") { q in
            let links = Dictionary(q.clips.compactMap { c in deltas[c.id].flatMap { d in c.linkID.map { ($0, d) } } }, uniquingKeysWith: { x, _ in x })
            for i in q.clips.indices {
                if let d = deltas[q.clips[i].id] {
                    q.clips[i].start += d
                } else if let l = q.clips[i].linkID, let d = links[l], !q.isLocked(q.clips[i].trackID) {
                    q.clips[i].start += d
                }
            }
        }
        return Outcome(plan: MCPDraft.plan(base: p, edits: [edit]), said: said)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
