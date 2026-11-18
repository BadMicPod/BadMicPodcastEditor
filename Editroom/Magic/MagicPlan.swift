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
    /// Drops new clips (a video and its linked audio) on the timeline.
    case place([Clip], asset: UUID)
    case trimHead([UUID], from: Double, to: Double)
    case trimTail([UUID], from: Double, to: Double)
    /// Moves clips in time and onto other tracks.
    case move([UUID], from: Double, to: Double, tracks: [UUID: UUID])
    case gain(UUID, from: Double, to: Double)
    case fadeIn(UUID, to: Double)
    case fadeOut(UUID, to: Double)
    case look(UUID, name: String)
    case grade(UUID, MagicGradeKey, to: Double)
    case transition(UUID, Transition)

    /// What the cursor's tag says while it does this.
    var label: String {
        switch self {
        case .place(let clips, _): return clips.first?.kind == .audio ? "Music" : "Place"
        case .trimHead, .trimTail: return "Trim"
        case .move: return "Move"
        case .gain(_, _, let to): return String(format: "%.0f dB", to).replacingOccurrences(of: "-", with: "−")
        case .fadeIn: return "Fade in"
        case .fadeOut: return "Fade out"
        case .look(_, let name): return name
        case .grade(_, let key, _): return key.label
        case .transition(_, let t): return t.kind.label
        }
    }

    /// How long the drag or click itself takes, in seconds.
    var performTime: Double {
        switch self {
        case .place: return 0.5
        case .trimHead, .trimTail: return 0.26
        case .move: return 0.32
        case .gain: return 0.22
        case .fadeIn, .fadeOut: return 0.2
        case .look: return 0.1
        case .grade: return 0.2
        case .transition: return 0.12
        }
    }

    /// The clip this edit happens on, for grouping and drawing.
    var clipID: UUID? {
        switch self {
        case .place(let clips, _): return clips.first?.id
        case .trimHead(let ids, _, _), .trimTail(let ids, _, _), .move(let ids, _, _, _): return ids.first
        case .gain(let id, _, _), .fadeIn(let id, _), .fadeOut(let id, _), .look(let id, _),
             .grade(let id, _, _), .transition(let id, _): return id
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
            guard p >= 1 else { return }
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
/// way an editor would by hand: drop each shot long, trim both ends, pull the shots onto one track,
/// grade them, set levels, add a few dissolves.
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

        // Shots: each clip used a few times, at different moments, so there's enough to cut.
        var rng = SeededRandom(seed: UInt64(visuals.count * 7919 + project.assets.count))
        let shotCount = min(16, max(8, visuals.count * 3))
        var shots: [(asset: MediaAsset, duration: Double, use: Int, uses: Int)] = []
        var uses: [UUID: Int] = [:]
        let perAsset = Int((Double(shotCount) / Double(visuals.count)).rounded(.up))
        for i in 0..<shotCount {
            let a = visuals[i % visuals.count]
            let n = uses[a.id, default: 0]
            uses[a.id] = n + 1
            var d = 1.3 + rng.next() * 0.9
            if a.kind == .video { d = min(d, max(0.6, a.duration / Double(perAsset) - 0.1)) }
            shots.append((a, (d * fps).rounded() / fps, n, perAsset))
        }

        // Where each shot ends up.
        var finalStart: [Double] = []
        var t = 0.0
        for s in shots { finalStart.append(t); t += s.duration }
        let total = t

        // Each shot is dropped with extra at both ends, on alternating tracks so the extras can overlap.
        let minDur = shots.map(\.duration).min() ?? 1
        let extra = (min(0.5, minDur * 0.32) * fps).rounded() / fps

        var tasks: [MagicTask] = []
        func add(_ e: MagicEdit, after: [Int] = [], delay: Double = 0) -> Int {
            tasks.append(MagicTask(edit: e, after: after, delay: delay))
            return tasks.count - 1
        }

        struct Placed { var video: UUID; var audio: UUID?; var place: Int; var head: Int?; var tail: Int?; var settled: Int? }
        var placed: [Placed] = []
        let look = "Film print"

        // Music first, so it's under everything from the start.
        var musicClip: UUID?
        if let music {
            let len = min(music.duration, total)
            let skip = music.duration - len > 20 ? min(30, (music.duration - len) * 0.3) : 0
            var c = Clip(trackID: base.audioTracks[2].id, kind: .audio, assetID: music.id, start: 0, duration: (len * fps).rounded() / fps)
            c.sourceStart = skip
            let p = add(.place([c], asset: music.id))
            musicClip = c.id
            _ = add(.fadeIn(c.id, to: 0.4), after: [p])
            _ = add(.fadeOut(c.id, to: min(1.5, len / 4)), after: [p], delay: 0.05)
        }

        for (i, s) in shots.enumerated() {
            let odd = i % 2 == 1
            let dur = s.duration
            // Spread a clip's shots across its length.
            var source = 0.0
            var head = i == 0 ? 0 : extra
            var tail = extra
            if s.asset.kind == .video {
                let slot = s.asset.duration / Double(s.uses)
                source = Double(s.use) * slot + max(0, (slot - dur) / 2)
                source = min(max(0, source), max(0, s.asset.duration - dur))
                head = min(head, (source * fps).rounded(.down) / fps)
                tail = min(tail, ((s.asset.duration - source - dur) * fps).rounded(.down) / fps)
            }
            head = max(0, head)
            tail = max(0, tail)
            let stagedStart = finalStart[i] - head
            let stagedDur = dur + head + tail

            var v = Clip(trackID: odd ? v2 : v1, kind: s.asset.kind == .image ? .image : .video, assetID: s.asset.id,
                         start: stagedStart, duration: stagedDur)
            v.sourceStart = source - head
            var group = [v]
            var audioID: UUID?
            if s.asset.kind == .video, s.asset.hasAudio {
                let link = UUID()
                group[0].linkID = link
                var au = Clip(trackID: odd ? a2 : a1, kind: .audio, assetID: s.asset.id, start: stagedStart, duration: stagedDur)
                au.sourceStart = v.sourceStart
                au.linkID = link
                group.append(au)
                audioID = au.id
            }
            let ids = group.map(\.id)
            let p = add(.place(group, asset: s.asset.id), after: [], delay: Double(i) * 0.012)
            var entry = Placed(video: v.id, audio: audioID, place: p, head: nil, tail: nil, settled: nil)
            if head > 0.5 / fps { entry.head = add(.trimHead(ids, from: stagedStart, to: finalStart[i]), after: [p]) }
            if tail > 0.5 / fps { entry.tail = add(.trimTail(ids, from: finalStart[i] + dur + tail, to: finalStart[i] + dur), after: [p], delay: 0.03) }
            placed.append(entry)
        }

        // Pull the shots on the second track down once their neighbours are trimmed.
        for i in placed.indices {
            var deps = [placed[i].place] + [placed[i].head, placed[i].tail].compactMap { $0 }
            guard i % 2 == 1 else {
                placed[i].settled = nil
                continue
            }
            if i > 0 { deps += [placed[i - 1].place] + [placed[i - 1].tail].compactMap { $0 } }
            if i + 1 < placed.count { deps += [placed[i + 1].place] + [placed[i + 1].head].compactMap { $0 } }
            var tracks = [placed[i].video: v1]
            var ids = [placed[i].video]
            if let a = placed[i].audio { tracks[a] = a1; ids.append(a) }
            placed[i].settled = add(.move(ids, from: finalStart[i], to: finalStart[i], tracks: tracks), after: deps)
        }

        for (i, s) in placed.enumerated() {
            let ready = [s.place] + [s.head, s.tail, s.settled].compactMap { $0 }
            // Grade: four cursors on one card at once.
            _ = add(.look(s.video, name: look), after: ready)
            // One grade for every shot, so the cut matches.
            _ = add(.grade(s.video, .exposure, to: 0.2), after: ready, delay: 0.025)
            _ = add(.grade(s.video, .contrast, to: 12), after: ready, delay: 0.05)
            _ = add(.grade(s.video, .saturation, to: 18), after: ready, delay: 0.075)
            // Shot sound sits under the music.
            if musicClip != nil, let a = s.audio {
                _ = add(.gain(a, from: 0, to: -16), after: ready, delay: 0.04)
            }
            // A dissolve on every fourth cut.
            if i > 0, i % 4 == 0 {
                let prev = placed[i - 1]
                let deps = ready + [prev.place] + [prev.head, prev.tail, prev.settled].compactMap { $0 }
                _ = add(.transition(s.video, Transition(kind: .dissolve, duration: 0.4)), after: deps, delay: 0.02)
            }
        }
        return MagicPlan(base: base, tasks: tasks)
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
