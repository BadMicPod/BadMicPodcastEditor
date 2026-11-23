import Foundation

/// Local's captions ("add captions", "subtitles please", "remove the captions"): the caption track, with what's
/// said in the picked clips, or with everyone talking in the edit. Words in quotes are a title, not captions.
@MainActor
enum LocalCaptions {
    static func asks(_ request: String, project p: Project) -> Bool {
        let t = request.lowercased()
        guard ["caption", "subtitle", "closed caption", "transcribe the", "words on screen as they talk"].contains(where: { t.contains($0) })
        else { return false }
        // "a caption saying 'Day one'" is a title; a new cut is left to Local's cut (captions can be asked for after).
        if t.range(of: #"(^|\s)["“'‘][^"”'’]{1,60}["”'’]"#, options: .regularExpression) != nil { return false }
        if LocalTitle.newCut(request) { return false }
        return removes(request) || p.clips.contains { $0.kind == .audio }
    }

    static func removes(_ request: String) -> Bool {
        let t = request.lowercased()
        return ["remove", "delete", "take off", "take away", "get rid", "no caption", "no subtitle", "without caption",
                "without subtitle", "turn off", "hide the caption", "hide caption"].contains { t.contains($0) }
    }

    /// The clips whose speech to caption: the picked ones (their sound), or everyone talking.
    static func targets(pointers: MagicPointers, project p: Project) -> Set<UUID> {
        let picked = p.captionTargets(Set(pointers.selected))
        return p.unlocked(picked.isEmpty ? p.defaultCaptionTargets : picked)
    }

    static func plan(request: String, pointers: MagicPointers, project p: Project,
                     transcript: (MediaAsset) -> Transcript?) -> LocalPointed.Outcome {
        if removes(request) {
            guard p.captions != nil else { return LocalPointed.Outcome(said: "There are no captions to remove.") }
            let edits: [MagicEdit] = [.change(nil, "No captions") { $0.removeCaptionTrack() }]
            return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: "Removed the captions.")
        }
        let targets = targets(pointers: pointers, project: p)
        guard !targets.isEmpty else {
            return LocalPointed.Outcome(said: "There's no one talking to caption. Pick a clip with sound and ask again.")
        }
        var after = p
        after.addCaptions(targets)
        let count = CaptionLayout.blocks(after, transcript: transcript).count
        let edits: [MagicEdit] = [.change(targets.first, "Captions") { $0.addCaptions(targets) }]
        let said = count == 0
            ? "Added a caption track, but no speech was heard in \(targets.count == 1 ? "that clip" : "those clips")."
            : "Captioned what's said: \(count) caption\(count == 1 ? "" : "s") on the caption track."
        return LocalPointed.Outcome(plan: MCPDraft.plan(base: p, edits: edits), said: said)
    }
}
