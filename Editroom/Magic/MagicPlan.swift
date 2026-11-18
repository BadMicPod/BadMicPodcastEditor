import Foundation

/// Grade controls a cursor can drag on a floating grade card.
enum MagicGradeKey: CaseIterable {
    case exposure, contrast, saturation

    var label: String {
        switch self {
        case .exposure: return "Exposure"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -2...2
        case .contrast: return -50...50
        case .saturation: return -100...100
        }
    }

    func value(_ g: ColorGrade?) -> Double {
        switch self {
        case .exposure: return g?.exposure ?? 0
        case .contrast: return g?.contrast ?? 0
        case .saturation: return g?.saturation ?? 0
        }
    }

    func set(_ g: inout ColorGrade, _ v: Double) {
        switch self {
        case .exposure: g.exposure = v
        case .contrast: g.contrast = v
        case .saturation: g.saturation = v
        }
    }
}

/// One small edit, the kind a person makes with one drag or click. Applied with a progress from 0 to
/// 1 so a drag can be shown happening.
enum MagicEdit {
    /// Drops new clips (a video and its linked audio, or a title) on the timeline. `asset` is the
    /// library item they're dragged from; nil for a title, which comes from the Text button.
    case place([Clip], asset: UUID?)
    case trimHead([UUID], from: Double, to: Double)
    case trimTail([UUID], from: Double, to: Double)
    /// Moves clips in time and onto other tracks.
    case move([UUID], from: Double, to: Double, tracks: [UUID: UUID])
    /// Cuts clips in two with the blade; the right-hand pieces get the given ids.
    case blade([UUID], at: Double, pieces: [UUID: UUID], link: UUID?)
    case remove([UUID])
    /// Types a title's text.
    case type(UUID, String)
    case gain(UUID, from: Double, to: Double)
    case fadeIn(UUID, to: Double)
    case fadeOut(UUID, to: Double)
    case look(UUID, name: String)
    case grade(UUID, MagicGradeKey, to: Double)
    case transition(UUID, Transition)

    /// What the cursor's tag says while it does this, `p` of the way through.
    func label(_ p: Double = 1) -> String {
        switch self {
        case .place(let clips, _):
            switch clips.first?.kind {
            case .audio: return "Music"
            case .text: return "Title"
            default: return "Place"
            }
        case .trimHead, .trimTail: return "Trim"
        case .move: return "Move"
        case .blade: return "✂ Cut"
        case .remove: return "Delete"
        case .type(_, let text):
            let n = Int((Double(text.count) * min(1, max(0, p))).rounded(.down))
            return String(text.prefix(n)) + (n < text.count ? "|" : "")
        case .gain(_, _, let to): return String(format: "%.0f dB", to).replacingOccurrences(of: "-", with: "−")
        case .fadeIn: return "Fade in"
        case .fadeOut: return "Fade out"
        case .look(_, let name): return name
        case .grade(_, let key, _): return key.label
        case .transition(_, let t): return t.kind.label
        }
    }

    var label: String { label(1) }

    /// How long the drag or click itself takes, in seconds.
    var performTime: Double {
        switch self {
        case .place: return 0.5
        case .trimHead, .trimTail: return 0.28
        case .move: return 0.42
        case .blade: return 0.16
        case .remove: return 0.14
        case .type(_, let text): return 0.12 + Double(text.count) * 0.045
        case .gain: return 0.24
        case .fadeIn, .fadeOut: return 0.22
        case .look: return 0.1
        case .grade: return 0.2
        case .transition: return 0.46
        }
    }

    /// The clip this edit happens on, for grouping and drawing.
    var clipID: UUID? { clipIDs.first }

    /// Every clip it changes.
    var clipIDs: [UUID] {
        switch self {
        case .place(let clips, _): return clips.map(\.id)
        case .trimHead(let ids, _, _), .trimTail(let ids, _, _), .move(let ids, _, _, _), .blade(let ids, _, _, _),
             .remove(let ids): return ids
        case .type(let id, _), .gain(let id, _, _), .fadeIn(let id, _), .fadeOut(let id, _), .look(let id, _),
             .grade(let id, _, _), .transition(let id, _): return [id]
        }
    }

    var isGradeCard: Bool {
        switch self {
        case .look, .grade: return true
        default: return false
        }
    }

    /// Applies the edit, `p` of the way through.
    func apply(_ project: inout Project, _ p: Double) {
        let e = MagicEase.inOut(min(1, max(0, p)))
        func each(_ ids: [UUID], _ body: (inout Clip) -> Void) {
            for id in ids { if let i = project.index(of: id) { body(&project.clips[i]) } }
        }
        switch self {
        case .place(let clips, _):
            guard p >= 1 else { return }
            project.clips.append(contentsOf: clips)
        case .trimHead(let ids, let from, let to):
            let t = project.snapFrame(from + (to - from) * e)
            each(ids) { $0.trimHead(to: t) }
        case .trimTail(let ids, let from, let to):
            let t = project.snapFrame(from + (to - from) * e)
            each(ids) { $0.trimTail(to: t) }
        case .move(let ids, let from, let to, let tracks):
            let delta = project.snapFrame(from + (to - from) * e) - from
            each(ids) { c in
                c.start += delta
                if e >= 0.5, let t = tracks[c.id] { c.trackID = t }
            }
        case .blade(let ids, let at, let pieces, let link):
            guard p >= 1 else { return }
            for id in ids {
                guard let i = project.index(of: id), let newID = pieces[id] else { continue }
                var right = project.clips[i]
                guard at > right.start, at < right.end else { continue }
                right.id = newID
                right.linkID = project.clips[i].linkID == nil ? nil : link
                right.fadeIn = 0
                right.trimHead(to: at)
                project.clips[i].fadeOut = 0
                project.clips[i].trimTail(to: at)
                project.clips.append(right)
            }
        case .remove(let ids):
            guard p >= 1 else { return }
            project.clips.removeAll { ids.contains($0.id) }
        case .type(let id, let text):
            let n = Int((Double(text.count) * min(1, max(0, p))).rounded(.down))
            each([id]) { $0.text.string = String(text.prefix(n)) }
        case .gain(let id, let from, let to):
            each([id]) { $0.gainDB = ((from + (to - from) * e) * 10).rounded() / 10 }
        case .fadeIn(let id, let to):
            each([id]) { $0.fadeIn = to * e; $0.clampFades() }
        case .fadeOut(let id, let to):
            each([id]) { $0.fadeOut = to * e; $0.clampFades() }
        case .look(let id, let name):
            // Grades change at the end of a drag: each new value re-grades the clip's thumbnails.
            guard p >= 1 else { return }
            each([id]) { var g = $0.grade ?? ColorGrade(); g.look = name; $0.grade = g }
        case .grade(let id, let key, let to):
            guard p >= 1 else { return }
            each([id]) { var g = $0.grade ?? ColorGrade(); key.set(&g, to); $0.grade = g }
        case .transition(let id, let t):
            guard p >= 0.85 else { return }
            each([id]) { $0.transitionIn = t }
        }
    }
}

enum MagicEase {
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func out(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
}

/// An edit with the edits that have to be finished before it can start.
struct MagicTask {
    var edit: MagicEdit
    var after: [Int] = []
    /// Extra wait after its dependencies are done, so a group of cursors arrives with a slight stagger.
    var delay = 0.0
}

/// A finished edit plan: the project to start from and the edits that build the cut.
struct MagicPlan {
    var base: Project
    var tasks: [MagicTask]
}

/// Step 1's stand-in for a real planner: a quick montage from whatever is in the library, built the
/// way an editor would by hand. A rough cut goes down first, shots long and in no particular order,
/// on V2. Handles are trimmed (some heads cut off with the blade) and each shot is dragged down into
/// its place on V1. Then a title, dissolves, sound levels and fades, and a grade on every shot.
enum ScriptedPlanner {
    static func plan(for project: Project, offline: Set<UUID>) -> MagicPlan? {
        let visuals = project.assets.filter { a in
            !offline.contains(a.id) && (a.kind == .image || (a.kind == .video && a.duration >= 1))
        }
        guard !visuals.isEmpty else { return nil }
        let music = project.assets.first { $0.kind == .audio && !offline.contains($0.id) && $0.duration >= 4 }

        var base = project
        base.clips = []
        base.inPoint = nil
        base.outPoint = nil
        while base.videoTracks.count < 2 { base.videoTracks.append(Track(kind: .video)) }
        while base.audioTracks.count < (music == nil ? 2 : 3) { base.audioTracks.append(Track(kind: .audio)) }
        for i in base.videoTracks.indices { base.videoTracks[i].locked = false }
        for i in base.audioTracks.indices { base.audioTracks[i].locked = false }
        let v1 = base.videoTracks[0].id, v2 = base.videoTracks[1].id
        let a1 = base.audioTracks[0].id, a2 = base.audioTracks[1].id
        let fps = base.fps
        func frames(_ t: Double) -> Double { (t * fps).rounded() / fps }

        // Shots: each clip used a few times, at different moments.
        var rng = SeededRandom(seed: UInt64(visuals.count * 7919 + project.assets.count))
        let shotCount = min(16, max(8, visuals.count * 3))
        let perAsset = Int((Double(shotCount) / Double(visuals.count)).rounded(.up))
        struct Shot { var asset: MediaAsset; var duration: Double; var source = 0.0; var head = 0.0; var tail = 0.0 }
        var shots: [Shot] = []
        var uses: [UUID: Int] = [:]
        for i in 0..<shotCount {
            let a = visuals[i % visuals.count]
            let n = uses[a.id, default: 0]
            uses[a.id] = n + 1
            var d = 1.3 + rng.next() * 0.9
            var shot = Shot(asset: a, duration: 0)
            // Generous handles: shots go down long and get trimmed.
            var head = 0.35 + rng.next() * 0.45, tail = 0.35 + rng.next() * 0.5
            if a.kind == .video {
                let slot = a.duration / Double(perAsset)
                d = min(d, max(0.6, slot - 0.1))
                shot.source = min(max(0, Double(n) * slot + max(0, (slot - d) / 2)), max(0, a.duration - d))
                head = min(head, shot.source)
                tail = min(tail, a.duration - shot.source - d)
            }
            shot.duration = frames(d)
            shot.head = max(0, (head * fps).rounded(.down) / fps)
            shot.tail = max(0, (tail * fps).rounded(.down) / fps)
            shots.append(shot)
        }

        // Where each shot ends up, in order on V1.
        var finalStart: [Double] = []
        var t = 0.0
        for s in shots { finalStart.append(t); t += s.duration }
        let total = t

        // The rough cut: the same shots, long, shuffled, one after another on V2.
        var rough = Array(shots.indices)
        for i in stride(from: rough.count - 1, to: 0, by: -1) { rough.swapAt(i, Int(rng.next() * Double(i + 1))) }
        var roughStart = Array(repeating: 0.0, count: shots.count)
        t = 0
        for i in rough { roughStart[i] = t; t += shots[i].head + shots[i].duration + shots[i].tail }

        var tasks: [MagicTask] = []
        func add(_ e: MagicEdit, after: [Int] = [], delay: Double = 0) -> Int {
            tasks.append(MagicTask(edit: e, after: after, delay: delay))
            return tasks.count - 1
        }

        // Music first, so it's under everything from the start.
        var musicClip: UUID?
        if let music {
            let len = min(music.duration, total)
            let skip = music.duration - len > 20 ? min(30, (music.duration - len) * 0.3) : 0
            var c = Clip(trackID: base.audioTracks[2].id, kind: .audio, assetID: music.id, start: 0, duration: frames(len))
            c.sourceStart = skip
            let p = add(.place([c], asset: music.id))
            musicClip = c.id
            _ = add(.fadeIn(c.id, to: 0.5), after: [p], delay: 0.1)
            _ = add(.fadeOut(c.id, to: min(1.5, len / 4)), after: [p], delay: 0.2)
            _ = add(.gain(c.id, from: 0, to: -2), after: [p], delay: 0.4)
        }

        struct Cut { var video: UUID; var audio: UUID?; var moved: Int; var roughEnd: Double; var roughFrom: Double }
        var cuts = Array(repeating: Cut(video: UUID(), audio: nil, moved: 0, roughEnd: 0, roughFrom: 0), count: shots.count)
        for (order, i) in rough.enumerated() {
            let s = shots[i]
            let r = roughStart[i]
            let long = s.head + s.duration + s.tail
            var v = Clip(trackID: v2, kind: s.asset.kind == .image ? .image : .video, assetID: s.asset.id, start: r, duration: long)
            v.sourceStart = s.source - s.head
            var group = [v]
            if s.asset.kind == .video, s.asset.hasAudio {
                let link = UUID()
                group[0].linkID = link
                var au = Clip(trackID: a2, kind: .audio, assetID: s.asset.id, start: r, duration: long)
                au.sourceStart = v.sourceStart
                au.linkID = link
                group.append(au)
            }
            var ids = group.map(\.id)
            let place = add(.place(group, asset: s.asset.id), delay: Double(order) * 0.05)
            var ready = [place]
            let headAt = r + s.head
            if s.head > 0.2, i % 3 == 1 {
                // Cut the head off with the blade and delete it.
                var pieces: [UUID: UUID] = [:]
                for id in ids { pieces[id] = UUID() }
                let blade = add(.blade(ids, at: headAt, pieces: pieces, link: UUID()), after: [place])
                let remove = add(.remove(ids), after: [blade], delay: 0.03)
                ids = ids.map { pieces[$0]! }
                ready = [blade, remove]
            } else if s.head > 0.5 / fps {
                ready.append(add(.trimHead(ids, from: r, to: headAt), after: [place]))
            }
            if s.tail > 0.5 / fps {
                ready.append(add(.trimTail(ids, from: r + long, to: headAt + s.duration), after: ready, delay: 0.02))
            }
            var tracks = [ids[0]: v1]
            if ids.count > 1 { tracks[ids[1]] = a1 }
            let moved = add(.move(ids, from: headAt, to: finalStart[i], tracks: tracks), after: ready)
            cuts[i] = Cut(video: ids[0], audio: ids.count > 1 ? ids[1] : nil, moved: moved, roughEnd: headAt + s.duration, roughFrom: headAt)
        }

        // A title on V2 once the rough cut has cleared from under it.
        let titleLength = min(3, max(2, total * 0.12))
        let clearing = cuts.filter { $0.roughFrom < titleLength }.map(\.moved)
        var title = Clip(trackID: v2, kind: .text, start: 0, duration: frames(titleLength))
        title.text.string = ""
        title.text.size = 130
        let titleText = Self.titleText()
        let placed = add(.place([title], asset: nil), after: clearing)
        let typed = add(.type(title.id, titleText), after: [placed])
        _ = add(.fadeIn(title.id, to: 0.4), after: [typed])
        _ = add(.fadeOut(title.id, to: 0.5), after: [typed], delay: 0.05)

        let look = "Film print"
        for (i, c) in cuts.enumerated() {
            // Sound: shot audio sits under the music, with little fades on and off.
            if let a = c.audio {
                if musicClip != nil {
                    _ = add(.gain(a, from: 0, to: i % 4 == 2 ? -9 : -16), after: [c.moved], delay: 0.03)
                }
                _ = add(i % 2 == 0 ? .fadeIn(a, to: 0.25) : .fadeOut(a, to: 0.3), after: [c.moved], delay: 0.08)
            }
            // Dissolves picked from the right-click menu.
            if i > 0, i % 3 == 0 || i == cuts.count - 1 {
                _ = add(.transition(c.video, Transition(kind: .dissolve, duration: 0.5)), after: [c.moved, cuts[i - 1].moved], delay: 0.1)
            }
            // Grade each shot as soon as it's in place, while others are still being cut: four
            // cursors on its panel.
            _ = add(.look(c.video, name: look), after: [c.moved], delay: 0.1)
            _ = add(.grade(c.video, .exposure, to: 0.2), after: [c.moved], delay: 0.125)
            _ = add(.grade(c.video, .contrast, to: 12), after: [c.moved], delay: 0.15)
            _ = add(.grade(c.video, .saturation, to: 18), after: [c.moved], delay: 0.175)
        }
        return MagicPlan(base: base, tasks: tasks)
    }

    /// The title: this month and year.
    static func titleText() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: Date())
    }
}

/// Repeatable randomness, so the same media always gives the same cut.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}
