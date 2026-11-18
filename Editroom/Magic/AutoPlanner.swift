import Foundation

/// What the cut should be, before anything is put on the timeline: which moments, how long, in what
/// order, over which part of the song. The choreographer turns it into edits the cursors perform.
struct EditDecision {
    struct Shot {
        var asset: MediaAsset
        /// Where the shot starts in its file.
        var source: Double
        var duration: Double
        /// Brings the shot to a matching brightness.
        var exposure: Double
        /// Level for the shot's own sound; 0 leaves it alone.
        var gainDB: Double
        /// A dissolve into this shot.
        var dissolve: Bool
        var score: Double
    }
    struct Music {
        var asset: MediaAsset
        var source: Double
        var duration: Double
        var fadeOut: Double
    }
    var shots: [Shot]
    var music: Music?
    var title: String
    var look: String
    var bpm: Double?
}

/// Picks the best moments from each clip and cuts them to the music, with no network and no key.
///
/// Each frame sample is scored for focus, exposure, colour, faces and steadiness (and Apple's
/// aesthetics score where the system has it). Windows of the right length are scored by their
/// samples, and shots are taken round-robin across the clips in the order they were filmed, so the
/// cut tells things in order without two shots from one clip side by side. With music, every shot is
/// a whole number of beats, cuts land on beats, the cut ends on a bar, and the song starts on a bar
/// where it lifts.
enum AutoPlanner {
    static func decide(project: Project, clips: [(MediaAsset, ClipAnalysis)], music: (MediaAsset, MusicAnalysis)?,
                       today: Date = Date()) -> EditDecision? {
        let usable = clips.filter { !$0.1.samples.isEmpty }
        guard !usable.isEmpty else { return nil }

        // Scores, with focus, motion and colour measured against all the footage.
        let all = usable.flatMap(\.1.samples)
        func pct(_ v: [Double], _ p: Double) -> Double {
            let s = v.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        let sharpLog = all.map { log1p($0.sharpness) }
        let s10 = pct(sharpLog, 0.1), s90 = max(pct(sharpLog, 0.9), s10 + 1e-6)
        let m90 = max(pct(all.map(\.motion), 0.9), 0.02)
        let c90 = max(pct(all.map(\.color), 0.9), 0.05)
        func score(_ s: ClipAnalysis.Sample) -> Double {
            let sharp = min(1, max(0, (log1p(s.sharpness) - s10) / (s90 - s10)))
            let exposure = 1 - min(1, abs(s.luma - 0.45) / 0.38)
            let color = min(1, s.color / c90)
            let motion = s.motion / m90
            var q = 0.36 * sharp + 0.2 * exposure + 0.14 * color
            q += s.faces > 0 ? 0.16 : 0
            q += s.aesthetic.map { 0.26 * ($0 + 1) / 2 } ?? 0.12
            if s.utility == true { q -= 0.35 }
            if motion > 1.1 { q -= min(0.3, (motion - 1.1) * 0.3) }
            return q
        }

        struct Source {
            var asset: MediaAsset
            var analysis: ClipAnalysis
            var scores: [Double]
            var picked: [(Double, Double)] = []
        }
        // In the order things were filmed; undated files keep their library order, last.
        var sources = usable.enumerated().map { i, c in
            (i, Source(asset: c.0, analysis: c.1, scores: c.1.samples.map(score)))
        }
        .sorted { a, b in
            switch (a.1.analysis.created, b.1.analysis.created) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0 < b.0
            }
        }
        .map(\.1)
        let allScores = sources.flatMap(\.scores)
        let floor = pct(allScores, 0.3)

        // Shot lengths: whole beats with music, a natural rhythm without.
        let period = music.map { $0.1.period }
        var longBeats = 4, shortBeats = 2
        if let p = period {
            longBeats = [2, 4, 8].first { Double($0) * p >= 1.5 } ?? 8
            shortBeats = Double(longBeats / 2) * p >= 0.8 ? longBeats / 2 : longBeats
        }
        let rhythm = [true, false, false, true, true, false]
        func beatsFor(_ k: Int) -> Int { rhythm[k % rhythm.count] ? longBeats : shortBeats }
        func lengthFor(_ k: Int) -> Double {
            if let p = period { return Double(beatsFor(k)) * p }
            return [2.4, 1.8, 2.1, 2.8, 1.7, 2.2][k % 6]
        }

        // How long: about half the good footage, between 12 and 40 seconds, and no longer than the song allows.
        let good = sources.reduce(0.0) { sum, s in
            let step = s.analysis.samples.count > 1 ? s.analysis.duration / Double(s.analysis.samples.count) : 2.5
            return sum + Double(s.scores.filter { $0 >= floor }.count) * step
        }
        var target = min(40, max(12, good * 0.5))
        if let m = music?.1 { target = min(target, m.duration - 2) }

        /// The best window of `length` in a source that doesn't overlap what's already been taken from it.
        func bestWindow(_ s: Source, _ length: Double) -> (start: Double, score: Double)? {
            let a = s.analysis
            if s.asset.kind == .image {
                return s.picked.isEmpty ? (0, s.scores.first ?? 0) : nil
            }
            // The project's idea of the file's length wins.
            let limit = min(a.duration, s.asset.duration)
            guard limit >= length + 0.1 else { return nil }
            var best: (Double, Double)?
            var start = 0.05
            while start + length <= limit - 0.05 {
                let end = start + length
                let clear = s.picked.allSatisfy { end + 0.3 <= $0.0 || start >= $0.1 + 0.3 }
                if clear {
                    let inside = a.samples.indices.filter { a.samples[$0].time >= start && a.samples[$0].time <= end }
                    if !inside.isEmpty {
                        let vals = inside.map { s.scores[$0] }
                        // The average, held down by the worst moment in it.
                        let v = vals.reduce(0, +) / Double(vals.count) * 0.75 + (vals.min() ?? 0) * 0.25
                        if best == nil || v > best!.1 { best = (start, v) }
                    }
                }
                start += 0.25
            }
            return best
        }

        var shots: [EditDecision.Shot] = []
        var shotBeats: [Int] = []
        var total = 0.0
        var round = 0
        while total < target {
            var added = 0
            for i in sources.indices where total < target {
                // A short clip that can't give a long shot can still give a short one.
                var length = lengthFor(shots.count)
                var beats = beatsFor(shots.count)
                var found = bestWindow(sources[i], length + 0.08)
                if found == nil, beats != shortBeats || period == nil {
                    beats = shortBeats
                    length = period.map { Double(shortBeats) * $0 } ?? 1.6
                    found = bestWindow(sources[i], length + 0.08)
                }
                guard let w = found else { continue }
                // Everything gets a shot in the first round if it has anything decent; after that, only
                // good moments, unless the cut would be too short to be worth watching.
                guard w.score >= (round == 0 || total < 18 ? pct(allScores, 0.12) : floor) else { continue }
                // Not two shots from one clip in a row.
                if shots.last?.asset.id == sources[i].asset.id, sources.count > 1 { continue }
                sources[i].picked.append((w.start, w.start + length))
                let luma = sources[i].analysis.samples.filter { $0.time >= w.start && $0.time <= w.start + length }.map(\.luma)
                let m = luma.isEmpty ? 0.45 : luma.reduce(0, +) / Double(luma.count)
                let exposure = ((log2(0.45 / max(0.05, m)) * 0.5).clamped(to: -0.5...0.5) * 10).rounded() / 10
                shots.append(EditDecision.Shot(asset: sources[i].asset, source: w.start, duration: length, exposure: exposure,
                                               gainDB: 0, dissolve: false, score: w.score))
                shotBeats.append(beats)
                total += length
                added += 1
            }
            if added == 0 { break }
            round += 1
        }
        guard !shots.isEmpty else { return nil }

        var decision = EditDecision(shots: shots, music: nil, title: title(for: usable.compactMap(\.1.created), today: today),
                                    look: "Film print", bpm: nil)

        if let (asset, m) = music, !m.beats.isEmpty {
            decision.bpm = m.bpm
            // End on a bar: lengthen the last shot to the bar line if its clip allows.
            let count = shotBeats.reduce(0, +)
            let extra = (4 - count % 4) % 4
            if extra > 0, let last = shots.indices.last {
                let s = shots[last]
                let needed = s.duration + Double(extra) * m.period
                // Longer at either end, as long as it stays in the file and clear of the clip's other shots.
                func fits(_ start: Double) -> Bool {
                    guard s.asset.kind == .video else { return true }
                    guard start >= 0, start + needed <= s.asset.duration - 0.05 else { return false }
                    return shots.indices.allSatisfy { j in
                        j == last || shots[j].asset.id != s.asset.id
                            || start + needed + 0.1 <= shots[j].source || start >= shots[j].source + shots[j].duration + 0.1
                    }
                }
                if let start = [s.source, s.source - (needed - s.duration)].first(where: fits) {
                    shotBeats[last] += extra
                    decision.shots[last].source = start
                } else if shotBeats[last] > 4 - extra {
                    shotBeats[last] -= 4 - extra
                } else if shotBeats[last] == 4 - extra, last > 0 {
                    // Exactly the overhang: leave it out.
                    shotBeats.removeLast()
                    decision.shots.removeLast()
                }
            }
            var totalBeats = shotBeats.reduce(0, +)
            // Drop shots from the end until the song is long enough.
            while totalBeats + 2 >= m.beats.count, shotBeats.count > 1 {
                totalBeats -= shotBeats.removeLast()
                decision.shots.removeLast()
            }
            // Start the song on a bar where it's lively and lifting.
            var best = (beat: m.barPhase, score: -Double.infinity)
            var b = m.barPhase
            while b + totalBeats + 1 < m.beats.count {
                let window = m.energy[b..<(b + totalBeats)]
                let mean = Double(window.reduce(0, +)) / Double(window.count)
                let before = b >= 8 ? Double(m.energy[(b - 8)..<b].reduce(0, +)) / 8 : mean
                let after = Double(m.energy[b..<min(m.energy.count, b + 8)].reduce(0, +)) / Double(min(8, m.energy.count - b))
                let s = mean + 0.5 * max(0, after - before) - (b == m.barPhase && b < 4 ? 0.05 : 0)
                if s > best.score { best = (b, s) }
                b += 4
            }
            let b0 = best.beat
            // Cut exactly on the song's beats (they drift a little from a strict grid).
            var at = b0
            for i in decision.shots.indices {
                let next = at + shotBeats[i]
                decision.shots[i].duration = m.beats[next] - m.beats[at]
                // On the first beat of each four-bar phrase, dissolve rather than cut.
                decision.shots[i].dissolve = i > 0 && (at - b0) % 16 == 0
                at = next
            }
            let length = m.beats[at] - m.beats[b0]
            let tail = min(1.2, max(0, m.duration - m.beats[at]))
            decision.music = EditDecision.Music(asset: asset, source: m.beats[b0], duration: length + tail, fadeOut: tail + 0.6)
            for i in decision.shots.indices where decision.shots[i].asset.hasAudio { decision.shots[i].gainDB = -16 }
        } else {
            for i in decision.shots.indices { decision.shots[i].dissolve = i > 0 && i % 4 == 0 }
        }
        // Keep shots inside their files after any lengthening.
        for i in decision.shots.indices where decision.shots[i].asset.kind == .video {
            let s = decision.shots[i]
            decision.shots[i].source = max(0, min(s.source, s.asset.duration - s.duration - 0.02))
        }
        return decision
    }

    /// The title: when it was filmed. "November 14, 2026", "November 2026" or "October – November 2026".
    static func title(for dates: [Date], today: Date) -> String {
        let f = DateFormatter()
        guard let first = dates.min(), let last = dates.max() else {
            f.dateFormat = "MMMM yyyy"
            return f.string(from: today)
        }
        let cal = Calendar.current
        if cal.isDate(first, inSameDayAs: last) {
            f.dateFormat = "MMMM d, yyyy"
            return f.string(from: first)
        }
        if cal.isDate(first, equalTo: last, toGranularity: .month) {
            f.dateFormat = "MMMM yyyy"
            return f.string(from: first)
        }
        f.dateFormat = "MMMM"
        let a = f.string(from: first)
        f.dateFormat = "MMMM yyyy"
        return a + " – " + f.string(from: last)
    }
}
