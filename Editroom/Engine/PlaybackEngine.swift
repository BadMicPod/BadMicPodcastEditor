import AVFoundation
import CoreImage
import QuartzCore

/// Owns the AVPlayer and swaps freshly built compositions in as the timeline changes.
@MainActor
final class PlaybackEngine {
    /// The player being watched and heard. While looping it swaps with `spare` at each loop.
    private(set) var player = AVPlayer()
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
        for p in [player, spare] {
            p.automaticallyWaitsToMinimizeStalling = false
            p.actionAtItemEnd = .pause
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                // Looping with the spare ready: it takes over, with no seek.
                if self.loopsItself {
                    if self.swapAt == nil { self.startSpare(in: 0) }
                    self.swapToSpare()
                    return
                }
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
            dropSpare()
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
            if spareSignature == signature, let s = spare.currentItem {
                s.videoComposition = built.videoComposition
                s.audioMix = built.audioMix
            }
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
        dropSpare()
        if let span = loopSpan { item.forwardPlaybackEndTime = CompositionBuilder.time(span.end) }
        player.replaceCurrentItem(with: item)
        videoOutput = output
        signature = built.signature
        isSeeking = false
        seek(to: time)
        if wasPlaying { player.playImmediately(atRate: 1) }
        if loopSpan != nil { primeSpare() }
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.playImmediately(atRate: 1)
    }

    func pause() {
        player.pause()
        cancelSwap()
    }

    /// Coalescing seek: only one seek is in flight, the latest request always wins. `fast` (scrubbing,
    /// skimming) lets the decoder land on the nearest frame it can show at once, within a little of
    /// the time, rather than decoding up from the last keyframe to the exact frame, which in long-GOP
    /// footage (a 4K screen recording, a phone clip) takes long enough to fall seconds behind a quick
    /// drag. The exact frame follows as soon as the scrub rests (`seek(to:)` again, not fast).
    func seek(to time: Double, fast: Bool = false) {
        targetTime = clamp(time)
        exactWanted = !fast
        cancelSwap()
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

    // MARK: Seamless looping

    /// Looping: a second player waits at the loop's start, already decoded, and starts at the very
    /// moment the first reaches the end (its own clock, not a seek), so the loop has no pause. Then
    /// they swap, and the one that finished goes back to wait at the start for the next time round.
    private var spare = AVPlayer()
    private var spareOutput: AVPlayerItemVideoOutput?
    /// The edit the spare's item was made from (a different one is made again).
    private var spareSignature: Int?
    /// The spare is at the loop's start, decoded, ready to start.
    private var spareReady = false
    private var priming = 0
    /// When the spare is set to start (host time, seconds).
    private var swapAt: Double?

    /// What's being looped while playing (nil: not looping). The player stops itself at its end.
    var loopSpan: (start: Double, end: Double)? {
        didSet {
            guard loopSpan?.start != oldValue?.start || loopSpan?.end != oldValue?.end else { return }
            player.currentItem?.forwardPlaybackEndTime = loopSpan.map { CompositionBuilder.time($0.end) } ?? .invalid
            if loopSpan == nil { dropSpare() } else { primeSpare() }
        }
    }

    /// The loop is taken care of here (the spare is ready, or already starting).
    var loopsItself: Bool { loopSpan != nil && (spareReady || swapAt != nil) }

    /// Each frame while playing: starts the spare just as the loop's end comes, and swaps once it has.
    func serviceLoop() {
        guard let span = loopSpan, player.currentItem != nil else { return }
        if let at = swapAt {
            if CACurrentMediaTime() >= at { swapToSpare() }
            return
        }
        guard spareReady, isPlaying else { return }
        let left = span.end - player.currentTime().seconds
        if left < 0.25 { startSpare(in: max(0, left)) }
    }

    /// Starts the waiting spare `seconds` from now, on the host clock.
    private func startSpare(in seconds: Double) {
        guard spareReady, swapAt == nil else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let at = CMTimeAdd(now, CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        spare.setRate(1, time: .invalid, atHostTime: at)
        swapAt = at.seconds
        spareReady = false
    }

    /// The spare is playing: it becomes the player, and the old one goes to wait at the start.
    private func swapToSpare() {
        guard swapAt != nil else { return }
        swapAt = nil
        let old = player, oldOutput = videoOutput
        player = spare
        videoOutput = spareOutput
        spare = old
        spareOutput = oldOutput
        spareSignature = signature
        old.pause()
        isSeeking = false
        primeSpare()
    }

    /// Stopped or moved before the spare took over: it goes back to waiting.
    private func cancelSwap() {
        guard swapAt != nil else { return }
        swapAt = nil
        spare.pause()
        primeSpare()
    }

    private func dropSpare() {
        priming += 1
        spareReady = false
        if swapAt != nil { spare.pause(); swapAt = nil }
        spare.replaceCurrentItem(with: nil)
        spareOutput = nil
        spareSignature = nil
    }

    /// Puts the spare at the loop's start, decoded and ready to go.
    private func primeSpare() {
        guard let span = loopSpan, let main = player.currentItem else { return }
        priming += 1
        let generation = priming
        spareReady = false
        let item: AVPlayerItem
        if spareSignature == signature, let current = spare.currentItem {
            item = current
        } else {
            item = AVPlayerItem(asset: main.asset)
            item.audioTimePitchAlgorithm = .spectral
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            item.add(output)
            spare.replaceCurrentItem(with: item)
            spareOutput = output
            spareSignature = signature
        }
        item.videoComposition = main.videoComposition
        item.audioMix = main.audioMix
        item.forwardPlaybackEndTime = CompositionBuilder.time(span.end)
        let player = spare
        Task { @MainActor [weak self] in
            for _ in 0..<150 where item.status != .readyToPlay || player.status != .readyToPlay {
                if item.status == .failed { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let self, generation == self.priming, item.status == .readyToPlay, player.status == .readyToPlay else { return }
            let landed = await player.seek(to: CompositionBuilder.time(span.start), toleranceBefore: .zero, toleranceAfter: .zero)
            guard landed, generation == self.priming, player.rate == 0 else { return }
            let ready = await player.preroll(atRate: 1)
            guard ready, generation == self.priming else { return }
            self.spareReady = true
        }
    }

    /// Pulls the newest decoded frame, if one arrived since the last call.
    func pullFrame() -> CVPixelBuffer? {
        if let at = swapAt, CACurrentMediaTime() >= at { swapToSpare() }
        if let ready = scrubReady {
            scrubReady = nil
            lastFrame = ready.buffer
            shownTime = ready.time
            return ready.buffer
        }
        if restorePlayerFrame {
            restorePlayerFrame = false
            if let back = lastPlayerFrame {
                lastFrame = back
                return back
            }
        }
        guard let output = videoOutput else { return nil }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        var shown = CMTime.zero
        let frame = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown)
        if frame != nil {
            lastFrame = frame
            lastPlayerFrame = frame
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
    private var scrubNext: (time: Double, pictures: [Int: CIImage], still: CIImage?)?
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
        scrubNext = (at, pictures, nil)
        drawScrubFrame()
        return true
    }

    /// The exact frame takes over: nothing drawn from scrub frames lands after this.
    /// One frame of a file filling the viewer (fitted, as the viewer fits the timeline): the new edge
    /// of a clip while it's trimmed. Drawn like a scrub frame, on the GPU straight into the viewer.
    func showStill(_ image: CIImage, orientation: CGImagePropertyOrientation, time: Double) {
        let src = orientation == .up ? image : image.oriented(orientation)
        let e = src.extent
        guard e.width > 0, e.height > 0 else { return }
        let size = renderSize
        let s = min(size.width / e.width, size.height / e.height)
        let fitted = src.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                                           tx: (size.width - e.width * s) / 2 - e.minX * s,
                                                           ty: (size.height - e.height * s) / 2 - e.minY * s))
        scrubNext = (time, [:], fitted.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))))
        stillShowing = true
        drawScrubFrame()
    }

    /// A still went up (a trim's edge): when it ends, the player's last frame comes back, since
    /// nothing may have changed to make it draw a new one.
    private var stillShowing = false
    private var lastPlayerFrame: CVPixelBuffer?
    private var restorePlayerFrame = false

    func endStill() {
        guard stillShowing else { return }
        stillShowing = false
        endScrubFrames()
        restorePlayerFrame = true
    }

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
                let image = job.still ?? TimelineCompositor.compose(instruction, at: job.time, output: size) { i, _ in job.pictures[i] }
                TimelineCompositor.context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
                // Tagged as the player's frames are, so the viewer shows them in the same colours.
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
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
