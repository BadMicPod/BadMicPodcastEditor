import Foundation

/// Local's titles on an edit that's already there ("add a title at the end", "put 'Day one' at the start"):
/// a title over the start, the end or the playhead, and nothing else changed.
@MainActor
enum LocalTitle {
    /// A title for the edit on the timeline, not a new cut that happens to have one.
    static func asks(_ request: String, project p: Project) -> Bool {
        let t = request.lowercased()
        let hasEdit = p.clips.contains { $0.kind == .video || $0.kind == .image }
        let newCut = ["new cut", "new edit", "new video", "montage", "recut", "re-cut", "from scratch", "start over"].contains { t.contains($0) }
        return hasEdit && !newCut && LocalBrain.titleAsked(request) != nil
    }

    enum Spot { case start, end, playhead }

    static func spot(_ request: String) -> Spot {
        let t = request.lowercased()
        if ["at the end", "the end", "ending", "end screen", "end card", "end title", "outro", "closing", "at the close", "last shot"]
            .contains(where: { t.contains($0) }) { return .end }
        if ["playhead", "here", "right now", "this point"].contains(where: { t.contains($0) }) { return .playhead }
        return .start
    }

    static func plan(request: String, playhead: Double, project p: Project) -> LocalPointed.Outcome {
        let edit = p.clips.filter { $0.kind == .video || $0.kind == .image }
        guard let first = edit.map(\.start).min(), let last = edit.map(\.end).max() else {
            return LocalPointed.Outcome(said: "There's no edit on the timeline to put a title on.")
        }
        let where_ = spot(request)
        let length = min(3, max(1, (last - first) * 0.25))
        let start: Double
        switch where_ {
        case .start: start = first
        case .end: start = max(first, last - length)
        case .playhead: start = min(max(first, playhead), max(first, last - length))
        }
        // Their words when quoted; otherwise a placeholder to type over.
        let words = LocalBrain.titleAsked(request).flatMap { $0.isEmpty ? nil : $0 } ?? "Title"

        // Above the picture: the first video track (not V1) that's free there, else a new one on top.
        var edits: [MagicEdit] = []
        let s = p.snapFrame(start), d = p.snapFrame(length)
        let track: UUID
        if let free = p.videoTracks.dropFirst().first(where: { t in
            !t.locked && !p.clips.contains { $0.trackID == t.id && $0.start < s + d && $0.end > s }
        }) {
            track = free.id
        } else {
            track = UUID()
            edits.append(.change(nil, "Add video track") { q in
                var t = Track(kind: .video)
                t.id = track
                q.videoTracks.append(t)
            })
        }
        var clip = Clip(trackID: track, kind: .text, start: s, duration: d)
        clip.text.string = ""
        clip.text.size = 130
        edits += [.place([clip], asset: nil), .type(clip.id, words), .fadeIn(clip.id, to: 0.4), .fadeOut(clip.id, to: 0.5)]
        let place = where_ == .end ? "over the last \(Int(length.rounded())) seconds" : where_ == .start ? "at the start" : "at the playhead"
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: "Added a title, \u{201C}\(words)\u{201D}, \(place).")
    }
}
