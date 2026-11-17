import Foundation
import QuartzCore

/// One meter's state: the level (with a falling release), the recent peak, and whether it has hit 0 dB.
struct MeterReading: Equatable {
    var level = MeterState.floor
    var peak = MeterState.floor
    /// Stays on once the signal reaches 0 dB, until the meter is clicked.
    var clipped = false

    func differs(from other: MeterReading) -> Bool {
        abs(level - other.level) > 0.2 || abs(peak - other.peak) > 0.2 || clipped != other.clipped
    }
}

/// Audio levels for the track and output meters, read from the waveform peaks at the playhead so
/// they need no hook into the audio itself. Values are dBFS.
@MainActor
final class MeterState: ObservableObject {
    static let floor = -60.0

    @Published private(set) var tracks: [UUID: MeterReading] = [:]
    @Published private(set) var master = MeterReading()

    /// How far the level may drop per display frame.
    private let release = 0.9
    /// How long a peak holds before it starts to fall, and how fast it falls after.
    private let peakHold = 1.2
    private let peakFall = 0.45
    private var holdUntil: [UUID?: Double] = [:]

    func resetClip(_ track: UUID?) {
        if let track {
            tracks[track]?.clipped = false
        } else {
            master.clipped = false
        }
    }

    func update(project: Project, media: MediaStore, time t: Double, playing: Bool) {
        let now = CACurrentMediaTime()
        var next: [UUID: MeterReading] = [:]
        var power = 0.0
        for track in project.audioTracks {
            var level = 0.0
            if playing, project.isAudible(track) {
                for c in project.clips where c.trackID == track.id && c.kind == .audio && t >= c.start && t < c.end {
                    guard let id = c.assetID, let wf = media.waveforms[id], !wf.peaks.isEmpty else { continue }
                    // The loudest peak over the last ~30ms of source.
                    let src = c.sourceStart + (t - c.start) * c.speed
                    let hi = min(wf.peaks.count - 1, Int(src * wf.peaksPerSecond))
                    let lo = max(0, Int((src - 0.03 * c.speed) * wf.peaksPerSecond))
                    guard hi >= lo else { continue }
                    var peak: Float = 0
                    for i in lo...hi { peak = max(peak, wf.peaks[i]) }
                    level = max(level, Double(peak) * dbToLinear(c.gainDB) * c.fadeGain(at: t))
                }
                level *= dbToLinear(track.gainDB)
            }
            power += level * level
            next[track.id] = advance(tracks[track.id] ?? MeterReading(), reading: Self.db(level), key: track.id, now: now)
        }
        let out = advance(master, reading: power > 0 ? 10 * log10(power) : Self.floor, key: nil, now: now)
        // Skip publishing tiny changes so idle meters don't redraw every frame.
        if next.count != tracks.count || next.contains(where: { $0.value.differs(from: tracks[$0.key] ?? MeterReading()) }) {
            tracks = next
        }
        if out.differs(from: master) { master = out }
    }

    private func advance(_ old: MeterReading, reading: Double, key: UUID?, now: Double) -> MeterReading {
        var r = old
        r.level = max(reading, max(Self.floor, old.level - release))
        if reading >= old.peak {
            r.peak = reading
            holdUntil[key] = now + peakHold
        } else if now > holdUntil[key] ?? 0 {
            r.peak = max(Self.floor, old.peak - peakFall)
        }
        if reading >= -0.1 { r.clipped = true }
        return r
    }

    private static func db(_ linear: Double) -> Double {
        linear > 0 ? max(floor, 20 * log10(linear)) : floor
    }
}
