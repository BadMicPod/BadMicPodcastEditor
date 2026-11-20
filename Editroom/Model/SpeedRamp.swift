import Foundation

/// A clip's speed changing over its footage: from `startSpeed`, easing into the clip's own speed
/// between `inFrom` and `inTo`, then easing out to `endSpeed` between `outFrom` and `outTo`. Times are
/// in the clip's source (seconds of footage), so a trim or a split just shows a different part of the
/// same curve, and each half of a split keeps its piece.
struct SpeedRamp: Codable, Hashable {
    var inFrom: Double
    var inTo: Double
    var outFrom: Double
    var outTo: Double
    var startSpeed: Double
    var endSpeed: Double

    /// Speed at a point in the footage, with `mid` the clip's own speed. Eased in log speed, so going
    /// from 100% to 400% feels as even as 400% to 100%.
    func speed(at s: Double, mid: Double) -> Double {
        if s < inTo {
            if s <= inFrom { return startSpeed }
            return Self.blend(startSpeed, mid, (s - inFrom) / (inTo - inFrom))
        }
        if s > outFrom {
            if s >= outTo { return endSpeed }
            return Self.blend(mid, endSpeed, (s - outFrom) / (outTo - outFrom))
        }
        return mid
    }

    private static func blend(_ a: Double, _ b: Double, _ u: Double) -> Double {
        let e = u * u * (3 - 2 * u)
        return exp(log(a) + (log(b) - log(a)) * e)
    }

    /// The fastest and slowest it plays.
    func extremes(mid: Double) -> (lo: Double, hi: Double) {
        let all = [startSpeed, mid, endSpeed]
        return (all.min()!, all.max()!)
    }

    /// Where the speed is constant: the pieces of footage between these marks.
    private var marks: [Double] { [inFrom, inTo, outFrom, outTo] }

    /// Timeline seconds to play footage from `s0` to `s1` (negative if `s1` is before `s0`).
    func span(from s0: Double, to s1: Double, mid: Double) -> Double {
        if s1 < s0 { return -span(from: s1, to: s0, mid: mid) }
        var total = 0.0
        var a = s0
        for m in marks + [s1] where m > a {
            let b = min(m, s1)
            total += piece(a, b, mid: mid)
            a = b
            if a >= s1 { break }
        }
        return total
    }

    /// One stretch with no mark inside it: exact if the speed is constant, else Simpson's rule.
    private func piece(_ a: Double, _ b: Double, mid: Double) -> Double {
        guard b > a else { return 0 }
        let va = speed(at: a, mid: mid), vb = speed(at: b, mid: mid), vm = speed(at: (a + b) / 2, mid: mid)
        if abs(va - vb) < 1e-12, abs(va - vm) < 1e-12 { return (b - a) / va }
        let n = 24
        let h = (b - a) / Double(n)
        var sum = 1 / va + 1 / vb
        for i in 1..<n { sum += (i % 2 == 0 ? 2 : 4) / speed(at: a + Double(i) * h, mid: mid) }
        return sum * h / 3
    }

    /// The footage reached after playing `dt` timeline seconds from `s0` (backwards if `dt` is negative).
    func source(from s0: Double, after dt: Double, mid: Double) -> Double {
        if abs(dt) < 1e-12 { return s0 }
        let forward = dt > 0
        var left = abs(dt)
        var a = s0
        let stops = forward ? marks.filter { $0 > s0 }.sorted() : marks.filter { $0 < s0 }.sorted(by: >)
        for m in stops {
            let t = abs(span(from: a, to: m, mid: mid))
            if t >= left { return solve(from: a, toward: m, time: left, mid: mid) }
            left -= t
            a = m
        }
        // Past every mark: constant from here.
        let v = speed(at: forward ? a + 1e-9 : a - 1e-9, mid: mid)
        return a + (forward ? 1 : -1) * left * v
    }

    /// Within one stretch: the point `time` timeline seconds from `a` toward `b`.
    private func solve(from a: Double, toward b: Double, time: Double, mid: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let m = (lo + hi) / 2
            if abs(span(from: a, to: a + (b - a) * m, mid: mid)) < time { lo = m } else { hi = m }
        }
        return a + (b - a) * (lo + hi) / 2
    }

    /// The same curve with the footage measured from somewhere else (`d` seconds later).
    func shifted(by d: Double) -> SpeedRamp {
        SpeedRamp(inFrom: inFrom + d, inTo: inTo + d, outFrom: outFrom + d, outTo: outTo + d, startSpeed: startSpeed, endSpeed: endSpeed)
    }

    /// The same curve measured from the other end of a file `length` long (for reversing a clip).
    func mirrored(length: Double) -> SpeedRamp {
        SpeedRamp(inFrom: length - outTo, inTo: length - outFrom, outFrom: length - inTo, outTo: length - inFrom,
                  startSpeed: endSpeed, endSpeed: startSpeed)
    }

    /// A ramp drawn over a clip's footage `s0...s1`, as the inspector's graph sets it: the first `a` and
    /// last `b` of it (fractions) ease from `start` and to `end`. Nil when there's no ramp at either end.
    static func drawn(s0: Double, s1: Double, a: Double, b: Double, start: Double, end: Double, mid: Double) -> SpeedRamp? {
        let L = s1 - s0
        let hasIn = a > 0.001, hasOut = b > 0.001
        guard hasIn || hasOut, L > 0 else { return nil }
        let inTo = s0 + L * (hasIn ? a : 0)
        let outFrom = s1 - L * (hasOut ? b : 0)
        return SpeedRamp(inFrom: s0, inTo: inTo, outFrom: max(inTo, outFrom), outTo: s1,
                         startSpeed: hasIn ? start : mid, endSpeed: hasOut ? end : mid)
    }
}

/// Which footage a clip shows at each moment, for the renderer.
struct SourceClock: Hashable {
    var start: Double
    var sourceStart: Double
    var speed: Double
    var ramp: SpeedRamp?

    init(_ clip: Clip) {
        start = clip.start
        sourceStart = clip.sourceStart
        speed = clip.isFreeze ? 0 : clip.speed
        ramp = clip.isFreeze ? nil : clip.ramp
    }

    func source(at t: Double) -> Double {
        guard let ramp else { return sourceStart + (t - start) * speed }
        return ramp.source(from: sourceStart, after: t - start, mid: speed)
    }
}

extension Clip {
    /// Speed changes across the clip.
    var isRamped: Bool { ramp != nil && playsSource }

    /// The speed at a point in its footage.
    func speed(atSource s: Double) -> Double {
        guard let ramp, playsSource else { return speed }
        return ramp.speed(at: s, mid: speed)
    }

    /// The footage showing at timeline time `t` (any time, before or after the clip too).
    func sourceTime(at t: Double) -> Double {
        guard let ramp, playsSource else { return sourceStart + (t - start) * speed }
        return ramp.source(from: sourceStart, after: t - start, mid: speed)
    }

    /// Footage the clip covers.
    var sourceLength: Double {
        guard isRamped else { return duration * speed }
        return sourceTime(at: end) - sourceStart
    }

    /// Timeline seconds to play footage from `s0` to `s1`.
    func timelineSpan(from s0: Double, to s1: Double) -> Double {
        guard let ramp, playsSource else { return (s1 - s0) / speed }
        return ramp.span(from: s0, to: s1, mid: speed)
    }

    /// The slowest and fastest it plays.
    var speedRange: (lo: Double, hi: Double) {
        guard let ramp, playsSource else { return (speed, speed) }
        return ramp.extremes(mid: speed)
    }

    /// Changes how it plays while keeping the same footage: its length follows.
    mutating func retime(snap: (Double) -> Double, minimum: Double, _ change: (inout Clip) -> Void) {
        guard playsSource else { change(&self); return }
        let s0 = sourceStart, length = sourceLength
        change(&self)
        duration = max(snap(timelineSpan(from: s0, to: s0 + length)), minimum)
        clampFades()
    }
}
