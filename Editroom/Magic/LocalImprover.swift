import Foundation

/// Local Magic on a timeline that already has an edit: makes that edit better instead of starting
/// over, with no AI. It keeps the person's shots, order and music, and:
/// - takes out repeats (the same part of the same file twice) and the weakest shots;
/// - trims long shots to their best moment, inside the part already chosen;
/// - with music, puts every cut on a beat and ends on a bar (and trims and fades the song to fit);
/// - closes the gaps;
/// - gives every shot the look most of them already have, evens out exposure, and sets the sound
///   (clips under the music, fades in and out).
/// The result is a list of ordinary Magic edits, played by the swarm as one undo step.
@MainActor
enum LocalImprover {
    struct Outcome {
        var plan: MagicPlan
        /// What changed, in a sentence, for the log and the note.
        var summary: String
        /// What it couldn't do of what was asked.
        var notes: [String] = []
    }

    /// `recipe` is what the person asked for (from Apple's on-device model), if anything. `newSong` is a song
    /// from the library to put under the edit when they asked for music and it has none; `music` is then
    /// that song's beats (otherwise the beats of the song already on the timeline).
    static func plan(project p: Project, analyses: [UUID: ClipAnalysis], music: MusicAnalysis?,
                     recipe: LocalRecipe = .plain, newSong: MediaAsset? = nil) -> Outcome? {
        // The main picture track: the lowest video track with shots on it.
        guard let track = p.videoTracks.first(where: { t in p.clips.contains { $0.trackID == t.id && isShot($0) } }),
              !p.isLocked(track.id) else { return nil }
        let shots = p.clips.filter { $0.trackID == track.id && isShot($0) }.sorted { $0.start < $1.start }
        guard !shots.isEmpty else { return nil }

        let all = shots.compactMap { $0.assetID.flatMap { analyses[$0] } }.flatMap(\.samples)
        let score = all.isEmpty ? { (_: ClipAnalysis.Sample) in 0.5 } : AutoPlanner.scorer(all)
        let fps = p.fps
        func frames(_ t: Double) -> Double { (t * fps).rounded() / fps }

        /// The part of the file a shot plays, in file time.
        func sourceRange(_ c: Clip) -> ClosedRange<Double> { c.sourceStart...(c.sourceStart + c.duration * c.speed) }

        /// The best window of `length` (timeline seconds) inside a shot's current part of its file.
        func best(_ c: Clip, length: Double) -> (sourceStart: Double, score: Double) {
            guard c.kind == .video, let id = c.assetID, let a = analyses[id], !a.samples.isEmpty else {
                return (c.sourceStart, shotScore(c))
            }
            let r = sourceRange(c), span = length * c.speed
            var bestStart = c.sourceStart, bestScore = -Double.infinity
            var s = r.lowerBound
            while s + span <= r.upperBound + 1e-6 {
                let inside = a.samples.filter { $0.time >= s && $0.time <= s + span }.map(score)
                if !inside.isEmpty {
                    let v = inside.reduce(0, +) / Double(inside.count) * 0.75 + (inside.min() ?? 0) * 0.25
                    if v > bestScore { bestScore = v; bestStart = s }
                }
                s += 0.1
            }
            return (bestStart, bestScore.isFinite ? bestScore : shotScore(c))
        }

        func shotScore(_ c: Clip) -> Double {
            guard let id = c.assetID, let a = analyses[id] else { return 0.5 }
            let r = sourceRange(c)
            let inside = a.samples.filter { c.kind == .image || r.contains($0.time) }.map(score)
            return inside.isEmpty ? 0.5 : inside.reduce(0, +) / Double(inside.count)
        }

        // 1. Repeats: the same file, mostly the same part. Keep the better-scoring one.
        var keep = shots
        var dropped: [Clip] = []
        var i = 0
        while i < keep.count {
            var j = i + 1
            while j < keep.count {
                let a = keep[i], b = keep[j]
                if a.assetID != nil, a.assetID == b.assetID, a.kind == b.kind {
                    let ra = sourceRange(a), rb = sourceRange(b)
                    let overlap = max(0, min(ra.upperBound, rb.upperBound) - max(ra.lowerBound, rb.lowerBound))
                    let shorter = max(0.01, min(ra.upperBound - ra.lowerBound, rb.upperBound - rb.lowerBound))
                    if a.kind == .image || overlap / shorter > 0.5 {
                        if shotScore(b) > shotScore(a) { dropped.append(a); keep[i] = b; keep.remove(at: j); continue }
                        dropped.append(b); keep.remove(at: j); continue
                    }
                }
                j += 1
            }
            i += 1
        }
        let repeats = dropped.count

        // 2. The weakest shots, when there are enough to spare: at most a quarter, never below four.
        if keep.count > 4 {
            let scores = keep.map(shotScore)
            let floor = AutoPlanner.percentile(scores, 0.15) - 0.05
            let weak = keep.indices.filter { scores[$0] < floor }.sorted { scores[$0] < scores[$1] }
            let canDrop = min(weak.count, keep.count / 4, keep.count - 4)
            let gone = Set(weak.prefix(canDrop).map { keep[$0].id })
            dropped += keep.filter { gone.contains($0.id) }
            keep.removeAll { gone.contains($0.id) }
        }
        // Back in timeline order (keeping the better of a repeat can swap which one stays).
        keep.sort { $0.start < $1.start }

        // 3. How long each shot plays, never longer than now: long ones come down to about their best 60%
        // (calm keeps more, fast keeps less).
        func paced(_ c: Clip) -> Double {
            switch recipe.pace {
            case .calm: return c.duration > 6 ? max(4, c.duration * 0.8) : c.duration
            case .fast: return c.duration > 2 ? max(1.2, min(2.5, c.duration * 0.5)) : c.duration
            case .unchanged: return c.duration > 3.5 ? min(c.duration, max(2.5, min(4.5, c.duration * 0.6))) : c.duration
            }
        }
        // A length they asked for: the weakest shots go while even shorter shots couldn't get there, then
        // every shot is shortened evenly.
        var notes: [String] = []
        var scale = 1.0
        if let target = recipe.seconds {
            var total = keep.map(paced).reduce(0, +)
            while total * 0.6 > target, keep.count > 2,
                  let weakest = keep.indices.min(by: { shotScore(keep[$0]) < shotScore(keep[$1]) }) {
                dropped.append(keep.remove(at: weakest))
                total = keep.map(paced).reduce(0, +)
            }
            scale = min(1, target / max(0.01, total))
            if total < target - 1 {
                notes.append("it can't be \(Int(target)) seconds long: your shots only add up to about \(Int(total.rounded()))")
            }
        }
        func wanted(_ c: Clip) -> Double { min(c.duration, max(0.8, paced(c) * scale)) }
        let weakOut = dropped.count - repeats

        // The song: the longest sound-only clip from a music file; none if they asked for no music; or a
        // song from the library put under the edit if they asked for music and there wasn't any.
        let songOnTimeline = p.clips.filter { $0.kind == .audio && $0.linkID == nil && p.asset($0.assetID ?? UUID())?.kind == .audio }
            .max { $0.duration < $1.duration }
        // Where the edit starts: where its first shot was, even if that shot is gone.
        let firstStart = shots.first!.start
        var song = recipe.music == .off ? nil : songOnTimeline
        var placing: Clip?
        if recipe.music == .add, songOnTimeline == nil, let newSong, let m = music {
            // From its first bar, so the cut starts on a downbeat.
            let bar = m.beats.indices.first { m.isBarStart($0) }.map { m.beats[$0] } ?? 0
            var c = Clip(trackID: UUID(), kind: .audio, assetID: newSong.id, start: firstStart, duration: max(1, newSong.duration - bar))
            c.sourceStart = bar
            placing = c
            song = c
        } else if recipe.music == .add, songOnTimeline == nil {
            notes.append("there's no music in your Media to add")
        }
        var cuts: [Double] = [firstStart]   // where each kept shot starts, then where the last one ends
        var lengths: [Double] = []
        if let song, let m = music, m.beats.count > 8 {
            // Beats on the timeline.
            let beats = m.beats.map { song.start + ($0 - song.sourceStart) / max(0.01, song.speed) }.filter { $0 > firstStart + 0.2 }
            let minLen = max(0.8, 2 * m.period)
            for (k, c) in keep.enumerated() {
                let last = k == keep.count - 1
                let from = cuts.last!
                let target = from + wanted(c)
                // A beat near where it wants to end, no later than the shot can go (the last shot may stretch
                // to reach a bar, as far as its file allows).
                let room = last ? (c.kind == .image ? 3600 : sourceRoom(c, p)) : c.duration
                let options = beats.enumerated().filter { $0.element >= from + minLen - 1e-6 && $0.element <= from + room + 1e-6 }
                let pick: Double
                if last {
                    // End on a bar: the bar start nearest the target that it can reach.
                    let bars = options.filter { m.isBarStart(beatIndex($0.offset, of: $0.element, in: m, song: song)) }
                    pick = (bars.min { abs($0.element - target) < abs($1.element - target) }
                            ?? options.min { abs($0.element - target) < abs($1.element - target) })?.element ?? from + min(wanted(c), room)
                } else {
                    pick = options.min { abs($0.element - target) < abs($1.element - target) }?.element ?? from + wanted(c)
                }
                lengths.append(frames(pick - from))
                cuts.append(from + lengths.last!)
            }
        } else {
            for c in keep {
                lengths.append(frames(wanted(c)))
                cuts.append(cuts.last! + lengths.last!)
            }
        }
        let newEnd = cuts.last!
        let oldEnd = shots.map(\.end).max() ?? newEnd

        // 4. The edits, in an order that's always safe: the frame shape first; repeats and weak shots out;
        // then each shot trimmed to its moment and slid left into place, left to right.
        var edits: [MagicEdit] = []
        let size: (Int, Int)? = switch recipe.frame {
        case .vertical: (1080, 1920)
        case .horizontal: (1920, 1080)
        case .square: (1080, 1080)
        case .unchanged: nil
        }
        if let size, p.width != size.0 || p.height != size.1 {
            edits.append(.change(nil, recipe.frame.rawValue.capitalized) { q in
                q.width = size.0
                q.height = size.1
                q.settingsLocked = true
            })
        }
        for c in dropped {
            edits.append(.remove(Array(p.unlocked(p.linked([c.id])))))
        }
        var trimmed = 0
        for (k, c) in keep.enumerated() {
            let ids = Array(p.unlocked(p.linked([c.id])))
            let length = lengths[k]
            var head = c.start
            if c.kind == .video, length < c.duration - 0.5 / fps {
                let w = best(c, length: length)
                head = frames(c.start + (w.sourceStart - c.sourceStart) / max(0.01, c.speed))
                if abs(head - c.start) > 0.5 / fps { edits.append(.trimHead(ids, from: c.start, to: head)) }
            }
            let tail = frames(head + length)
            let oldTail = c.end
            if abs(tail - oldTail) > 0.5 / fps {
                edits.append(.trimTail(ids, from: oldTail, to: tail))
                trimmed += 1
            }
            let target = frames(cuts[k])
            if abs(target - head) > 0.5 / fps {
                edits.append(.move(ids, from: head, to: target, tracks: [:]))
            }
        }

        // 5. Titles and overlays above: the same title twice at the same time goes (the lower one stays),
        // and anything past the new end is shortened or goes.
        let order = Dictionary(p.videoTracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let titles = p.clips.filter { $0.kind == .text }.sorted { (order[$0.trackID] ?? 0) < (order[$1.trackID] ?? 0) }
        var doubled = Set<UUID>()
        for (k, t) in titles.enumerated() where !doubled.contains(t.id) {
            for u in titles[(k + 1)...] where !doubled.contains(u.id) && u.text.string == t.text.string
                && u.start < t.end && u.end > t.start && !p.isLocked(u.trackID) {
                doubled.insert(u.id)
                edits.append(.remove([u.id]))
            }
        }
        for c in p.clips where c.trackID != track.id && p.videoTracks.contains(where: { $0.id == c.trackID })
            && !p.isLocked(c.trackID) && !doubled.contains(c.id) {
            if c.start >= newEnd - 0.2 {
                edits.append(.remove([c.id]))
            } else if c.end > newEnd {
                edits.append(.trimTail([c.id], from: c.end, to: newEnd))
            }
        }

        // 6. Sound: the song trimmed to the new end and faded out (or taken out, or put in); the clips' own
        // sound under it.
        let keptIDs = Set(keep.map(\.id))
        let keptAudio = p.clips.filter { a in a.kind == .audio && a.linkID != nil && keep.contains { $0.linkID == a.linkID } }
        if recipe.music == .off, let s = songOnTimeline, !p.isLocked(s.trackID) {
            edits.append(.remove([s.id]))
        }
        if var c = placing, let newSong {
            // On a sound track that's free for the whole edit, or a new one.
            if let free = p.audioTracks.first(where: { t in !p.isLocked(t.id) && !p.clips.contains { $0.trackID == t.id && $0.start < newEnd && $0.end > firstStart } }) {
                c.trackID = free.id
            } else {
                let id = UUID()
                edits.append(.change(nil, "Add audio track") { q in
                    var t = Track(kind: .audio)
                    t.id = id
                    q.audioTracks.append(t)
                })
                c.trackID = id
            }
            c.duration = frames(newEnd - firstStart)
            edits.append(.place([c], asset: newSong.id))
            edits.append(.fadeOut(c.id, to: min(2, c.duration * 0.15)))
            for a in keptAudio where a.gainDB > -10 { edits.append(.gain(a.id, from: a.gainDB, to: -16)) }
        } else if let song, !p.isLocked(song.trackID) {
            if song.end > newEnd + 1e-3 { edits.append(.trimTail([song.id], from: song.end, to: newEnd)) }
            if song.fadeOut < 1.5 { edits.append(.fadeOut(song.id, to: min(2, max(0.5, (min(song.end, newEnd) - song.start) * 0.15)))) }
            for a in keptAudio where a.gainDB > -10 {
                edits.append(.gain(a.id, from: a.gainDB, to: -16))
            }
        } else if let first = keptAudio.min(by: { $0.start < $1.start }), let last = keptAudio.max(by: { $0.start < $1.start }) {
            if first.fadeIn < 0.2 { edits.append(.fadeIn(first.id, to: 0.3)) }
            if last.fadeOut < 0.3 { edits.append(.fadeOut(last.id, to: 0.6)) }
        }

        // 7. One look: the one they asked for, or the one most of the shots have, on all of them (or looks
        // off, if they asked); and exposure evened out.
        let looks = keep.compactMap { $0.grade?.look }
        let common = recipe.look ?? Dictionary(looks.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
        var graded = 0
        for c in keep where keptIDs.contains(c.id) && c.kind != .audio {
            if common == "none" {
                if c.grade?.look != nil {
                    let id = c.id
                    edits.append(.change(id, "No look") { q in
                        if let i = q.index(of: id) { var g = q.clips[i].grade ?? ColorGrade(); g.look = nil; q.clips[i].grade = g.isNeutral ? nil : g }
                    })
                    graded += 1
                }
            } else if let common, c.grade?.look != common {
                edits.append(.look(c.id, name: common))
                graded += 1
            }
            if (c.grade?.exposure ?? 0) == 0, let id = c.assetID, let a = analyses[id] {
                let r = sourceRange(c)
                let lumas = a.samples.filter { c.kind == .image || r.contains($0.time) }.map(\.luma)
                if !lumas.isEmpty {
                    let mean = lumas.reduce(0, +) / Double(lumas.count)
                    let exposure = ((log2(0.45 / max(0.05, mean)) * 0.5).clamped(to: -0.5...0.5) * 10).rounded() / 10
                    if abs(exposure) >= 0.2 { edits.append(.grade(c.id, .exposure, to: exposure)) }
                }
            }
        }

        guard !edits.isEmpty else { return nil }
        var parts: [String] = [String(format: "%.1fs to %.1fs", oldEnd - firstStart, newEnd - firstStart)]
        if repeats > 0 { parts.append("\(repeats) repeat\(repeats == 1 ? "" : "s") out") }
        if !doubled.isEmpty { parts.append("\(doubled.count) doubled title\(doubled.count == 1 ? "" : "s") out") }
        if weakOut > 0 { parts.append("\(weakOut) weak shot\(weakOut == 1 ? "" : "s") out") }
        if trimmed > 0 { parts.append("\(trimmed) shot\(trimmed == 1 ? "" : "s") trimmed") }
        if placing != nil { parts.append("music added") } else if recipe.music == .off && songOnTimeline != nil { parts.append("music out") }
        if song != nil && music != nil { parts.append("cut to the beat") }
        if graded > 0 { parts.append(common == "none" ? "looks off" : "one look (\(common ?? ""))") }
        if recipe.frame != .unchanged, size != nil { parts.append(recipe.frame.rawValue) }
        return Outcome(plan: MCPDraft.plan(base: p, edits: edits), summary: parts.joined(separator: ", "), notes: notes)
    }

    /// Video and photo clips that make up the cut (not titles or solids).
    private static func isShot(_ c: Clip) -> Bool { (c.kind == .video || c.kind == .image) && c.assetID != nil }

    /// How long a shot could run from its start to the end of its file.
    private static func sourceRoom(_ c: Clip, _ p: Project) -> Double {
        guard let limit = p.sourceLimit(c) else { return c.duration }
        return max(c.duration, (limit - c.sourceStart) / max(0.01, c.speed))
    }

    /// The song's own beat number for a timeline beat (the list was filtered, so offsets shift).
    private static func beatIndex(_ offset: Int, of time: Double, in m: MusicAnalysis, song: Clip) -> Int {
        let sourceTime = song.sourceStart + (time - song.start) * song.speed
        return m.beats.indices.min { abs(m.beats[$0] - sourceTime) < abs(m.beats[$1] - sourceTime) } ?? offset
    }
}
