import Foundation

/// Audio levels for the track and output meters, read from the waveform peaks at the playhead so
/// they need no hook into the audio itself. Values are dBFS as shown, with a falling release.
@MainActor
final class MeterState: ObservableObject {
    static let floor = -60.0

    @Published private(set) var tracks: [UUID: Double] = [:]
    @Published private(set) var master = MeterState.floor

    /// How far a reading may drop per display frame.
    private let release = 0.9

    func update(project: Project, media: MediaStore, time t: Double, playing: Bool) {
        var next: [UUID: Double] = [:]
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
            next[track.id] = settle(tracks[track.id] ?? Self.floor, toward: Self.db(level))
        }
        let out = settle(master, toward: power > 0 ? 10 * log10(power) : Self.floor)
        // Skip publishing tiny changes so idle meters don't redraw every frame.
        if next.contains(where: { abs($0.value - (tracks[$0.key] ?? Self.floor)) > 0.2 }) || next.count != tracks.count {
            tracks = next
        }
        if abs(out - master) > 0.2 { master = out }
    }

    private static func db(_ linear: Double) -> Double {
        linear > 0 ? max(floor, 20 * log10(linear)) : floor
    }

    private func settle(_ shown: Double, toward reading: Double) -> Double {
        max(reading, max(Self.floor, shown - release))
    }
}
