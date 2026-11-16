import AVFoundation
import QuartzCore

/// Owns the AVPlayer and swaps freshly built compositions in as the timeline changes.
@MainActor
final class PlaybackEngine {
    let player = AVPlayer()
    private(set) var duration: Double = 0
    private(set) var fps: Double = 30
    private var videoOutput: AVPlayerItemVideoOutput?
    private var signature: Int?
    private var isSeeking = false
    private var targetTime: Double = 0
    private var endObserver: NSObjectProtocol?

    var onEnded: (() -> Void)?
    var isEmpty: Bool { player.currentItem == nil }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.onEnded?()
            }
        }
    }

    var isPlaying: Bool { player.rate != 0 }

    var currentTime: Double {
        if isSeeking { return targetTime }
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : targetTime
    }

    /// Rebuilds the player item. Changes that don't alter the edit structure only swap the video composition and mix.
    func rebuild(project: Project, media: MediaStore, at time: Double) {
        fps = project.fps
        guard let built = CompositionBuilder.build(project: project, media: media,
                                                   renderSize: CompositionBuilder.previewSize(for: project)) else {
            player.replaceCurrentItem(with: nil)
            videoOutput = nil
            signature = nil
            duration = 0
            isSeeking = false
            return
        }
        duration = built.duration

        if built.signature == signature, let item = player.currentItem {
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            if !isPlaying { refresh(at: time) }
            return
        }

        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        item.add(output)

        let wasPlaying = isPlaying
        player.replaceCurrentItem(with: item)
        videoOutput = output
        signature = built.signature
        isSeeking = false
        seek(to: time)
        if wasPlaying { player.playImmediately(atRate: 1) }
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.playImmediately(atRate: 1)
    }

    func pause() {
        player.pause()
    }

    /// Coalescing exact seek: only one seek is in flight, the latest request always wins.
    func seek(to time: Double) {
        targetTime = clamp(time)
        guard player.currentItem != nil else { return }
        if !isSeeking { performSeek() }
    }

    private var refreshPending = false

    private func refresh(at time: Double) {
        targetTime = clamp(time)
        if isSeeking { refreshPending = true } else { performSeek() }
    }

    private func clamp(_ t: Double) -> Double {
        max(0, min(t, duration - 0.5 / fps))
    }

    private func performSeek() {
        guard let item = player.currentItem else { isSeeking = false; return }
        isSeeking = true
        let t = targetTime
        player.seek(to: CompositionBuilder.time(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if abs(self.targetTime - t) > 1e-6 || self.refreshPending {
                    self.refreshPending = false
                    self.performSeek()
                } else {
                    self.isSeeking = false
                }
            }
        }
    }

    /// Pulls the newest decoded frame, if one arrived since the last call.
    func pullFrame() -> CVPixelBuffer? {
        guard let output = videoOutput else { return nil }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }
}
