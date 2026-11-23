import Foundation

/// Local's "add one more clip to the end", "add two shots at the start", "add @Beach at the end": clips put on
/// the edit that's there. Files named in the request are used; otherwise library clips not in the edit yet, in
/// library order. Each is a shot as long as the edit's own (2–5 seconds), from the middle of its file.
@MainActor
enum LocalAdd {
    static func asks(_ request: String, project p: Project) -> Bool {
        let t = " " + request.lowercased() + " "
        let verb = [" add ", " put ", " append ", " insert ", " stick ", " throw in ", " include "].contains { t.contains($0) }
        let thing = [" clip", " shot", " video", " photo", " picture", " image"].contains { t.contains($0) }
        let more = [" more ", " another ", " extra ", " end", " start", " beginning", " front", " last", " first"].contains { t.contains($0) }
        let hasEdit = p.clips.contains { $0.kind == .video || $0.kind == .image }
        // A new cut ("make a new video with 5 clips") is Local's cut, not clips added to this one.
        let newCut = ["new cut", "new edit", "new video", "montage", "recut", "re-cut", "from scratch", "start over",
                      "make a", "make an", "make me", "create", "build a"].contains { t.contains($0) }
        return verb && thing && more && hasEdit && !newCut
    }

    /// How many they asked for ("one more", "two shots", "3 clips"); one when it doesn't say.
    static func count(_ request: String) -> Int {
        let words = request.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let named = ["one": 1, "a": 1, "an": 1, "another": 1, "two": 2, "couple": 2, "three": 3, "few": 3, "four": 4, "five": 5,
                     "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        for (i, w) in words.enumerated() {
            guard i + 1 < words.count || Int(w) != nil else { continue }
            let rest = words[(i + 1)...].prefix(3)
            guard rest.contains(where: { ["clip", "clips", "shot", "shots", "video", "videos", "photo", "photos", "more"].contains($0) }) else { continue }
            if let n = Int(w) { return min(max(n, 1), 20) }
            if let n = named[w] { return n }
        }
        return 1
    }

    static func atStart(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["at the start", "the beginning", "at the front", "to the start", "to the front", "first shot", "open with", "start with"]
            .contains { t.contains($0) }
    }

    static func plan(request: String, typed: String, project p: Project) -> LocalPointed.Outcome {
        let visual = p.clips.filter { $0.kind == .video || $0.kind == .image }
        guard let first = visual.map(\.start).min(), let last = visual.map(\.end).max() else {
            return LocalPointed.Outcome(said: "There's no edit on the timeline to add to.")
        }
        // The files they named; else what isn't in the edit yet.
        let named = MagicMention.find(in: typed, media: p.assets).compactMap { m -> UUID? in
            if case .media(let id) = m.mention { return id } else { return nil }
        }
        let used = Set(p.clips.compactMap(\.assetID))
        let pool = named.isEmpty
            ? p.assets.filter { ($0.kind == .video || $0.kind == .image) && !used.contains($0.id) }.map(\.id)
            : named.filter { id in p.asset(id).map { $0.kind != .audio } ?? false }
        guard !pool.isEmpty else {
            return LocalPointed.Outcome(said: named.isEmpty
                ? "Every clip in your library is already in the edit. Import more, or name the one to use with @."
                : "Those are sound files, not clips to show.")
        }
        let n = named.isEmpty ? min(count(request), pool.count) : pool.count

        // As long as the edit's shots (their middle length), 2 to 5 seconds.
        let lengths = visual.map(\.duration).sorted()
        let typical = min(5, max(2, lengths[lengths.count / 2]))
        let start = atStart(request)
        let v1 = p.videoTracks[0].id, a1 = p.audioTracks[0].id

        var shots: [Clip] = []
        var at = start ? first : last
        for id in pool.prefix(n) {
            guard let asset = p.asset(id) else { continue }
            let d = p.snapFrame(asset.kind == .image ? typical : min(typical, asset.duration))
            guard d > 0 else { continue }
            let source = asset.kind == .image ? 0 : max(0, (asset.duration - d) / 2)
            var v = Clip(trackID: v1, kind: asset.kind == .image ? .image : .video, assetID: id, start: at, duration: d, sourceStart: source)
            if asset.kind == .video, asset.hasAudio {
                let link = UUID()
                v.linkID = link
                var a = Clip(trackID: a1, kind: .audio, assetID: id, start: at, duration: d, sourceStart: source)
                a.linkID = link
                shots += [v, a]
            } else {
                shots.append(v)
            }
            at += d
        }
        guard !shots.isEmpty else { return LocalPointed.Outcome(said: "Those clips are too short to use.") }
        let added = at - (start ? first : last)

        var edits: [MagicEdit] = []
        if start {
            // Everything moves along to make room at the front.
            let all = p.unlocked(Set(p.clips.map(\.id)))
            edits.append(.move(Array(all), from: first, to: first + added, tracks: [:]))
        } else {
            // Sound already on A1 past the end (music): the new clips' sound goes on a track of its own.
            let busy = p.clips.contains { $0.trackID == a1 && $0.end > last + 1e-6 }
            if busy, shots.contains(where: { $0.kind == .audio }) {
                let track = UUID()
                edits.append(.change(nil, "Add audio track") { q in
                    var t = Track(kind: .audio)
                    t.id = track
                    q.audioTracks.append(t)
                })
                for i in shots.indices where shots[i].kind == .audio { shots[i].trackID = track }
            }
        }
        // One file at a time, dragged in from the library.
        var placed: [Clip] = []
        for c in shots where c.kind != .audio {
            let pair = [c] + shots.filter { $0.kind == .audio && $0.linkID != nil && $0.linkID == c.linkID }
            edits.append(.place(pair, asset: c.assetID))
            placed.append(c)
        }
        let names = placed.compactMap { p.asset($0.assetID)?.name }
        let list = names.count <= 3 ? names.joined(separator: ", ") : "\(names.count) clips"
        let said = "Added \(list) \(start ? "at the start" : "at the end"), \(String(format: "%.1f", added)) seconds."
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: said)
    }
}
