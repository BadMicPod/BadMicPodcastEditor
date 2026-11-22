import AVFoundation
import CoreImage
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
    /// A seek is still on its way (testing).
    var seekInFlight: Bool { isSeeking }

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
        instruction = built.videoComposition.instructions.first as? TimelineInstruction
        renderSize = built.videoComposition.renderSize

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

    /// Coalescing seek: only one seek is in flight, the latest request always wins. `fast` (scrubbing,
    /// skimming) lets the decoder land on the nearest frame it can show at once, within a little of
    /// the time, rather than decoding up from the last keyframe to the exact frame, which in long-GOP
    /// footage (a 4K screen recording, a phone clip) takes long enough to fall seconds behind a quick
    /// drag. The exact frame follows as soon as the scrub rests (`seek(to:)` again, not fast).
    func seek(to time: Double, fast: Bool = false) {
        targetTime = clamp(time)
        exactWanted = !fast
        guard player.currentItem != nil else { return }
        if !isSeeking { performSeek() }
    }

    /// Whether the latest request wants the exact frame, and whether the seek in flight is exact.
    private var exactWanted = true
    private var seekingExact = true

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
        let exact = exactWanted
        seekingExact = exact
        let slack = exact ? CMTime.zero : CMTime(seconds: 0.75, preferredTimescale: 600)
        player.seek(to: CompositionBuilder.time(t), toleranceBefore: slack, toleranceAfter: slack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if abs(self.targetTime - t) > 1e-6 || self.refreshPending || (self.exactWanted && !exact) {
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
        if let ready = scrubReady {
            scrubReady = nil
            lastFrame = ready.buffer
            shownTime = ready.time
            return ready.buffer
        }
        guard let output = videoOutput else { return nil }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        var shown = CMTime.zero
        let frame = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown)
        if frame != nil {
            lastFrame = frame
            if shown.isNumeric { shownTime = shown.seconds }
        }
        return frame
    }

    // MARK: Scrubbing from made-ahead frames

    /// The timeline as the player has it, for compositing scrub frames the same way.
    private var instruction: TimelineInstruction?
    private var renderSize = CGSize(width: 1920, height: 1080)
    private let scrubQueue = DispatchQueue(label: "editroom.scrub", qos: .userInteractive)
    private var scrubBusy = false
    /// The latest scrub frame asked for, waiting for the one being drawn.
    private var scrubNext: (time: Double, pictures: [Int: CIImage])?
    /// A drawn scrub frame for the viewer's next refresh.
    private var scrubReady: (buffer: CVPixelBuffer, time: Double)?
    /// Bumped when scrubbing ends, so a frame still being drawn doesn't land over the exact one.
    private var scrubGeneration = 0
    private var scrubPool: CVPixelBufferPool?
    private var scrubPoolSize = CGSize.zero

    /// Shows the frame at `t` composited from made-ahead frames, if every video layer showing then has
    /// them. False when it can't (the player's seek has to do).
    func showScrubFrame(at t: Double, cache: ScrubCache) -> Bool {
        guard let instruction, !isPlaying else { return false }
        let at = clamp(t) + 1e-4
        var pictures: [Int: CIImage] = [:]
        for (i, layer) in instruction.layers.enumerated() where at >= layer.start && at < layer.end {
            switch layer.source {
            case .track, .reversed, .decoded:
                guard let s = layer.scrub, let img = cache.image(s.asset, at: s.time(at: at)) else { return false }
                pictures[i] = img
            default: continue
            }
        }
        scrubNext = (at, pictures)
        drawScrubFrame()
        return true
    }

    /// The exact frame takes over: nothing drawn from scrub frames lands after this.
    func endScrubFrames() {
        scrubGeneration += 1
        scrubNext = nil
        scrubReady = nil
    }

    private func drawScrubFrame() {
        guard !scrubBusy, let job = scrubNext, let instruction else { return }
        scrubNext = nil
        scrubBusy = true
        let size = renderSize
        if scrubPool == nil || scrubPoolSize != size {
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ] as CFDictionary, &pool)
            scrubPool = pool
            scrubPoolSize = size
        }
        let pool = scrubPool
        let generation = scrubGeneration
        scrubQueue.async { [weak self] in
            var buffer: CVPixelBuffer?
            if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
            if let buffer {
                let image = TimelineCompositor.compose(instruction, at: job.time, output: size) { i, _ in job.pictures[i] }
                TimelineCompositor.context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scrubBusy = false
                    if let buffer, generation == self.scrubGeneration { self.scrubReady = (buffer, job.time) }
                    self.drawScrubFrame()
                }
            }
        }
    }

    /// The time of the frame last handed to the viewer (testing).
    private(set) var shownTime: Double = 0

    /// The most recent frame handed out, so a viewer that appears later can show it straight away.
    private(set) var lastFrame: CVPixelBuffer?
}
