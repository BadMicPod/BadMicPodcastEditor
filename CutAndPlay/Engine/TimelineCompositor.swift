import AVFoundation
import CoreImage
import Metal

/// One visual element on the timeline, already resolved for a specific render size.
struct RenderLayer {
    enum Source {
        case track(CMPersistentTrackID, CGImagePropertyOrientation)
        case image(CIImage)
        case color(CIColor)
    }

    /// When the layer is drawn: the clip, plus any extra a transition shows before or after it.
    let start: Double
    let end: Double
    /// The clip itself, which its own fades are measured from.
    let fadeStart: Double
    let fadeEnd: Double
    let reveal: TransitionEdge?
    let conceal: TransitionEdge?
    let fadeIn: Double
    let fadeOut: Double
    let inCurve: FadeCurve
    let outCurve: FadeCurve
    let source: Source
    /// Baked colour cube for this clip's grade, if it has one.
    let cube: Data?
    let transform: ClipTransform?

    init(clip: Clip, source: Source, cube: Data? = nil, plan: TransitionPlan = TransitionPlan()) {
        self.cube = cube
        transform = clip.transform.flatMap { $0.isIdentity ? nil : $0 }
        start = clip.start - plan.leadIn
        end = clip.end + plan.tailOut
        fadeStart = clip.start
        fadeEnd = clip.end
        reveal = plan.reveal
        conceal = plan.conceal
        fadeIn = clip.fadeIn
        fadeOut = clip.fadeOut
        inCurve = clip.inCurve
        outCurve = clip.outCurve
        self.source = source
    }

    func opacity(at t: Double) -> Double {
        var o = 1.0
        // The clip's own fades; in the extra a transition shows, they hold their value at that end.
        let ft = min(max(t, fadeStart), fadeEnd)
        if fadeIn > 0 { o = min(o, inCurve.apply((ft - fadeStart) / fadeIn)) }
        if fadeOut > 0 { o = min(o, outCurve.apply((fadeEnd - ft) / fadeOut)) }
        if let r = reveal, r.kind != .wipe { o *= r.progress(t) }
        if let c = conceal { o *= 1 - c.progress(t) }
        return max(0, min(1, o))
    }

    /// For a wipe in progress, how much of the picture (from the left) is showing.
    func wipe(at t: Double) -> Double? {
        guard let r = reveal, r.kind == .wipe, t < r.end else { return nil }
        let p = r.progress(t)
        return p * p * (3 - 2 * p)
    }
}

/// A single instruction spans the whole timeline; the compositor resolves what is visible per frame.
final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    /// Bottom-most first.
    let layers: [RenderLayer]

    init(timeRange: CMTimeRange, layers: [RenderLayer], trackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        self.layers = layers
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
    }
}

final class TimelineCompositor: NSObject, AVVideoCompositing {
    static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private let queue = DispatchQueue(label: "cutandplay.compositor", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    // Take frames in the decoder's own YUV formats (8- and 10-bit), so a 4K frame isn't converted to
    // RGB on the way in; Core Image converts on the GPU as part of compositing.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let gen = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = gen != self.generation
            self.lock.unlock()
            if stale {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? TimelineInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "CutAndPlay", code: 1))
                return
            }
            let image = Self.compose(instruction, request: request)
            let size = request.renderContext.size
            Self.context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
            request.finish(withComposedVideoFrame: output)
        }
    }

    private static func compose(_ instruction: TimelineInstruction, request: AVAsynchronousVideoCompositionRequest) -> CIImage {
        let t = request.compositionTime.seconds + 1e-4
        let size = request.renderContext.size
        let frame = CGRect(origin: .zero, size: size)
        var out = CIImage(color: .black).cropped(to: frame)

        for layer in instruction.layers where t >= layer.start && t < layer.end {
            let opacity = layer.opacity(at: t)
            if opacity <= 0.001 { continue }
            var image: CIImage
            switch layer.source {
            case .track(let id, let orientation):
                guard let buffer = request.sourceFrame(byTrackID: id) else { continue }
                var src = CIImage(cvPixelBuffer: buffer)
                if orientation != .up { src = src.oriented(orientation) }
                let e = src.extent
                guard e.width > 0, e.height > 0 else { continue }
                let s = min(size.width / e.width, size.height / e.height)
                let tx = (size.width - e.width * s) / 2 - e.minX * s
                let ty = (size.height - e.height * s) / 2 - e.minY * s
                image = src.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
            case .image(let img):
                image = img
            case .color(let color):
                image = CIImage(color: color).cropped(to: frame)
            }
            if let w = layer.wipe(at: t) {
                image = image.cropped(to: CGRect(x: 0, y: 0, width: size.width * w, height: size.height))
            }
            if let tf = layer.transform {
                // Scale about the frame's centre, then offset (Core Image's y runs up).
                let cx = size.width / 2, cy = size.height / 2
                let m = CGAffineTransform(translationX: -cx, y: -cy)
                    .concatenating(CGAffineTransform(scaleX: tf.scale, y: tf.scale))
                    .concatenating(CGAffineTransform(translationX: cx + tf.x * size.width, y: cy - tf.y * size.height))
                image = image.transformed(by: m)
            }
            if let cube = layer.cube {
                image = image.applyingFilter("CIColorCube", parameters: [
                    "inputCubeDimension": GradeCube.dimension,
                    "inputCubeData": cube,
                ])
            }
            if opacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                ])
            }
            out = image.composited(over: out)
        }
        return out.cropped(to: frame)
    }
}
