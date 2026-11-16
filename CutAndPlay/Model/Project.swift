import Foundation
import CoreGraphics

// MARK: - Value types

struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
}

enum TrackKind: String, Codable { case video, audio }

struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: TrackKind
    var hidden = false
    var muted = false
    var gainDB: Double = 0
}

enum ClipKind: String, Codable {
    case video, audio, image, solid, text
    var trackKind: TrackKind { self == .audio ? .audio : .video }
    var usesSource: Bool { self == .video || self == .audio }
}

struct TextStyle: Codable, Hashable {
    var string = "Text"
    /// Font family; empty means the system font.
    var fontName = ""
    var bold = true
    /// Point size relative to a 1080px tall frame.
    var size: Double = 110
    var color = RGBA.white
    var x = 0.5
    var y = 0.5
}

enum FadeCurve: String, Codable, CaseIterable {
    case linear, easeIn, easeOut, smooth

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Exponential"
        case .easeOut: return "Logarithmic"
        case .smooth: return "S-Curve"
        }
    }

    /// Maps fade progress (0 = silent/transparent, 1 = full) through the curve.
    func apply(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .smooth: return x * x * (3 - 2 * x)
        }
    }
}

struct Clip: Identifiable, Codable, Hashable {
    var id = UUID()
    var trackID: UUID
    var kind: ClipKind
    var assetID: UUID?
    var start: Double
    var duration: Double
    var sourceStart: Double = 0
    var speed: Double = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var fadeInCurve: FadeCurve?
    var fadeOutCurve: FadeCurve?
    var gainDB: Double = 0
    var linkID: UUID?
    var color = RGBA(r: 0.16, g: 0.16, b: 0.2, a: 1)
    var text = TextStyle()

    var end: Double { start + duration }
    var inCurve: FadeCurve { fadeInCurve ?? .linear }
    var outCurve: FadeCurve { fadeOutCurve ?? .linear }

    mutating func clampFades() {
        fadeIn = min(max(0, fadeIn), duration)
        fadeOut = min(max(0, fadeOut), duration - fadeIn)
    }

    mutating func trimHead(to t: Double) {
        let d = t - start
        start = t
        duration -= d
        if kind.usesSource { sourceStart = max(0, sourceStart + d * speed) }
        clampFades()
    }

    mutating func trimTail(to t: Double) {
        duration = t - start
        clampFades()
    }
}

enum MediaKind: String, Codable { case video, audio, image }

struct MediaAsset: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    /// Set when the original had to be converted to something AVFoundation can decode.
    var playablePath: String?
    var name: String
    var kind: MediaKind
    var duration: Double
    var width: Int
    var height: Int
    var fps: Double
    var hasAudio: Bool

    var url: URL { URL(fileURLWithPath: playablePath ?? path) }
}

enum TrackToken {
    /// Placeholder track ids used while a drag targets a track that doesn't exist yet.
    static let newVideo = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let newAudio = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
}

// MARK: - Project

struct Project: Codable, Equatable {
    var width = 1920
    var height = 1080
    var fps: Double = 30
    var settingsLocked = false
    /// Index 0 is the bottom-most video track (V1).
    var videoTracks: [Track] = [Track(kind: .video), Track(kind: .video)]
    /// Index 0 is the top-most audio track (A1).
    var audioTracks: [Track] = [Track(kind: .audio), Track(kind: .audio)]
    var clips: [Clip] = []
    var assets: [MediaAsset] = []
    /// Remembered so repeat exports don't ask again.
    var exportName: String?
    var exportDir: String?
}

extension Project {
    static let minClip = 1.0 / 60.0

    var duration: Double { clips.map(\.end).max() ?? 0 }
    var size: CGSize { CGSize(width: width, height: height) }
    var aspect: CGFloat { CGFloat(width) / CGFloat(max(1, height)) }

    func snapFrame(_ t: Double) -> Double { (t * fps).rounded() / fps }

    func asset(_ id: UUID?) -> MediaAsset? {
        guard let id else { return nil }
        return assets.first { $0.id == id }
    }

    func clip(_ id: UUID) -> Clip? { clips.first { $0.id == id } }
    func index(of id: UUID) -> Int? { clips.firstIndex { $0.id == id } }

    func tracks(_ kind: TrackKind) -> [Track] { kind == .video ? videoTracks : audioTracks }

    func trackIndex(_ id: UUID, kind: TrackKind) -> Int? {
        tracks(kind).firstIndex { $0.id == id }
    }

    func name(of clip: Clip) -> String {
        switch clip.kind {
        case .text:
            let s = clip.text.string.replacingOccurrences(of: "\n", with: " ")
            return s.isEmpty ? "Text" : s
        case .solid: return "Solid"
        default: return asset(clip.assetID)?.name ?? "Missing"
        }
    }

    /// Expands a set of clip ids to include everything linked to them.
    func linked(_ ids: Set<UUID>) -> Set<UUID> {
        let links = Set(clips.filter { ids.contains($0.id) }.compactMap(\.linkID))
        guard !links.isEmpty else { return ids }
        return ids.union(clips.filter { $0.linkID.map(links.contains) ?? false }.map(\.id))
    }

    func sourceLimit(_ clip: Clip) -> Double? {
        guard clip.kind.usesSource else { return nil }
        return asset(clip.assetID)?.duration
    }

    /// Every clip edge (plus zero) that things can snap to.
    func snapTargets(excluding ids: Set<UUID>) -> [Double] {
        var out: [Double] = [0]
        for c in clips where !ids.contains(c.id) {
            out.append(c.start)
            out.append(c.end)
        }
        return out
    }

    /// Sorted, de-duplicated edit points for playhead jumping.
    var editPoints: [Double] {
        var set = Set<Double>([0])
        for c in clips { set.insert(c.start); set.insert(c.end) }
        return set.sorted()
    }

    /// Allowed delta range for dragging a clip edge.
    func trimLimits(_ c: Clip, left: Bool, excluding ids: Set<UUID>) -> ClosedRange<Double> {
        let others = clips.filter { $0.trackID == c.trackID && !ids.contains($0.id) && $0.id != c.id }
        let minDur = max(Project.minClip, 1 / fps)
        if left {
            let prevEnd = others.filter { $0.end <= c.start + 1e-6 }.map(\.end).max() ?? 0
            var lo = prevEnd - c.start
            if c.kind.usesSource { lo = max(lo, -c.sourceStart / c.speed) }
            let hi = c.duration - minDur
            return min(lo, hi)...hi
        } else {
            let nextStart = others.filter { $0.start >= c.end - 1e-6 }.map(\.start).min() ?? .infinity
            var hi = nextStart - c.end
            if let limit = sourceLimit(c) {
                hi = min(hi, (limit - c.sourceStart) / c.speed - c.duration)
            }
            let lo = minDur - c.duration
            return lo...max(lo, hi)
        }
    }

    /// First track of a kind (bottom-up for video, top-down for audio) that is empty across a range.
    func freeTrack(_ kind: TrackKind, start: Double, duration: Double) -> UUID? {
        for t in tracks(kind) {
            let busy = clips.contains { $0.trackID == t.id && $0.start < start + duration - 1e-6 && $0.end > start + 1e-6 }
            if !busy { return t.id }
        }
        return nil
    }

    // MARK: Mutations

    @discardableResult
    mutating func addTrack(_ kind: TrackKind) -> UUID {
        let t = Track(kind: kind)
        if kind == .video { videoTracks.append(t) } else { audioTracks.append(t) }
        return t.id
    }

    mutating func removeTrack(_ id: UUID) {
        if let i = videoTracks.firstIndex(where: { $0.id == id }), videoTracks.count > 1 {
            videoTracks.remove(at: i)
            clips.removeAll { $0.trackID == id }
        } else if let i = audioTracks.firstIndex(where: { $0.id == id }), audioTracks.count > 1 {
            audioTracks.remove(at: i)
            clips.removeAll { $0.trackID == id }
        }
    }

    mutating func updateTrack(_ id: UUID, _ body: (inout Track) -> Void) {
        if let i = videoTracks.firstIndex(where: { $0.id == id }) { body(&videoTracks[i]) }
        if let i = audioTracks.firstIndex(where: { $0.id == id }) { body(&audioTracks[i]) }
    }

    /// Replaces placeholder track tokens with freshly created tracks.
    mutating func materializeTokens() {
        var newV: UUID?, newA: UUID?
        for i in clips.indices {
            if clips[i].trackID == TrackToken.newVideo {
                if newV == nil { newV = addTrack(.video) }
                clips[i].trackID = newV!
            } else if clips[i].trackID == TrackToken.newAudio {
                if newA == nil { newA = addTrack(.audio) }
                clips[i].trackID = newA!
            }
        }
    }

    /// Overwrite edit: the given clips win, anything underneath is trimmed, split or removed.
    mutating func resolveOverlaps(keeping ids: Set<UUID>) {
        let eps = 1e-6
        for m in clips.filter({ ids.contains($0.id) }) {
            var result: [Clip] = []
            result.reserveCapacity(clips.count + 1)
            for var c in clips {
                if ids.contains(c.id) || c.trackID != m.trackID || c.end <= m.start + eps || c.start >= m.end - eps {
                    result.append(c)
                    continue
                }
                let head = c.start < m.start - eps
                let tail = c.end > m.end + eps
                if head && tail {
                    var right = c
                    right.id = UUID()
                    right.linkID = nil
                    right.fadeIn = 0
                    right.trimHead(to: m.end)
                    c.fadeOut = 0
                    c.trimTail(to: m.start)
                    result.append(c)
                    result.append(right)
                } else if head {
                    c.trimTail(to: m.start)
                    result.append(c)
                } else if tail {
                    c.trimHead(to: m.end)
                    result.append(c)
                }
            }
            clips = result
        }
    }

    /// Splits clips at a time. Returns ids of the new right-hand pieces.
    @discardableResult
    mutating func split(ids: Set<UUID>, at t: Double) -> Set<UUID> {
        let minDur = 0.5 / fps
        var created = Set<UUID>()
        var linkMap: [UUID: UUID] = [:]
        for id in ids {
            guard let i = index(of: id) else { continue }
            let c = clips[i]
            guard t > c.start + minDur, t < c.end - minDur else { continue }
            var right = c
            right.id = UUID()
            right.fadeIn = 0
            right.trimHead(to: t)
            if let l = c.linkID {
                let mapped = linkMap[l] ?? UUID()
                linkMap[l] = mapped
                right.linkID = mapped
            }
            clips[i].fadeOut = 0
            clips[i].trimTail(to: t)
            clips.append(right)
            created.insert(right.id)
        }
        return created
    }

    mutating func remove(ids: Set<UUID>, ripple: Bool) {
        let removed = clips.filter { ids.contains($0.id) }.sorted { $0.start > $1.start }
        clips.removeAll { ids.contains($0.id) }
        guard ripple else { return }
        for r in removed {
            for i in clips.indices where clips[i].trackID == r.trackID && clips[i].start >= r.end - 1e-6 {
                clips[i].start = max(0, clips[i].start - r.duration)
            }
        }
    }

    /// Changes playback speed of the given clips, keeping each one's source span.
    /// Changed clips on a track stay butted together (later ones slide by however much earlier ones
    /// grew or shrank), and anything that would be overlapped is pushed later instead.
    mutating func setSpeed(ids: Set<UUID>, speed: Double) {
        let speed = min(max(speed, 0.05), 100)
        for track in videoTracks + audioTracks {
            let order = clips.indices.filter { clips[$0].trackID == track.id }.sorted { clips[$0].start < clips[$1].start }
            guard order.contains(where: { ids.contains(clips[$0].id) && clips[$0].kind.usesSource }) else { continue }
            var shift = 0.0
            var prevEnd = 0.0
            for i in order {
                var c = clips[i]
                if ids.contains(c.id), c.kind.usesSource {
                    let newDuration = max(snapFrame(c.duration * c.speed / speed), 1 / fps)
                    c.start += shift
                    shift += newDuration - c.duration
                    c.speed = speed
                    c.duration = newDuration
                    c.clampFades()
                } else if ids.contains(c.id) {
                    c.start += shift
                }
                c.start = max(c.start, prevEnd)
                prevEnd = c.end
                clips[i] = c
            }
        }
    }

    /// Breaks the link between the given clips and their partners.
    mutating func unlink(ids: Set<UUID>) {
        let all = linked(ids)
        for i in clips.indices where all.contains(clips[i].id) { clips[i].linkID = nil }
    }

    mutating func sanitize() {
        let trackIDs = Set(videoTracks.map(\.id) + audioTracks.map(\.id))
        clips.removeAll { !trackIDs.contains($0.trackID) || $0.duration <= 1e-6 }
        for i in clips.indices {
            clips[i].start = max(0, clips[i].start)
            clips[i].clampFades()
        }
    }
}

// MARK: - Helpers

enum Timecode {
    static func string(_ t: Double, fps: Double) -> String {
        let f = max(1, Int(fps.rounded()))
        let total = Int((max(0, t) * fps).rounded())
        let frames = total % f
        let secs = total / f
        let s = secs % 60, m = (secs / 60) % 60, h = secs / 3600
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
    }

    static func short(_ t: Double) -> String {
        let secs = Int(max(0, t).rounded())
        let s = secs % 60, m = (secs / 60) % 60, h = secs / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

func dbToLinear(_ db: Double) -> Double {
    db <= -59.5 ? 0 : pow(10, db / 20)
}

func formatDB(_ db: Double) -> String {
    if db <= -59.5 { return "−∞ dB" }
    let v = (db * 10).rounded() / 10
    return (v > 0 ? "+" : v < 0 ? "−" : "") + String(format: "%.1f dB", abs(v))
}
