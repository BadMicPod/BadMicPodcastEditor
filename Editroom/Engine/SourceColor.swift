import AVFoundation
import CoreImage

/// How a video file's picture is encoded, so HDR and Log footage can be shown and exported as
/// ordinary Rec.709 like everything else on the timeline. Each kind has a colour cube that turns its
/// pixel values straight into Rec.709 ones: undo the file's curve, move Rec.2020 colours into
/// Rec.709, ease highlights brighter than white down so they roll off instead of clipping, and
/// encode with the Rec.709 curve.
enum SourceColor: Equatable {
    /// Rec.709 / sRGB: shown as is.
    case standard
    /// HDR with the HLG curve (iPhone HDR, including Dolby Vision 8.4).
    case hlg
    /// HDR10 / PQ.
    case pq
    /// Apple Log (iPhone 15 Pro and later); Apple Log 2 is read the same way.
    case appleLog

    var isStandard: Bool { self == .standard }

    static func of(_ track: AVAssetTrack) -> SourceColor {
        guard let fd = track.formatDescriptions.first else { return .standard }
        let desc = fd as! CMFormatDescription
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] ?? [:]
        // "LogTransferFunction" is "com.apple.rec2020.apple-log" (or apple-log2). Spelled out, so it
        // works on macOS versions older than the SDK's named constants.
        if let log = ext["LogTransferFunction"] as? String, log.lowercased().contains("apple-log") {
            return .appleLog
        }
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { return .hlg }
        if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
        return .standard
    }

    // MARK: Conversion

    static let dimension = 64
    private static let lock = NSLock()
    private static var cubes: [String: Data] = [:]

    /// Converts a frame (as Core Image reads it from the decoder, curve still applied) to Rec.709.
    func toRec709(_ image: CIImage) -> CIImage {
        guard let cube = cube else { return image }
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": Self.dimension,
            "inputCubeData": cube,
        ])
    }

    private var cube: Data? {
        let key: String
        switch self {
        case .standard: return nil
        case .hlg: key = "hlg"
        case .pq: key = "pq"
        case .appleLog: key = "log"
        }
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let hit = Self.cubes[key] { return hit }
        let n = Self.dimension
        var values = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rgb = convert(Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                    let i = ((b * n + g) * n + r) * 4
                    values[i] = Float(rgb.0); values[i + 1] = Float(rgb.1); values[i + 2] = Float(rgb.2)
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        Self.cubes[key] = data
        return data
    }

    /// One encoded Rec.2020 colour to encoded Rec.709, with white (diffuse, not peak) at 1.
    func convert(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        // Linear light, scaled so the format's reference white is 1.
        let lin = [r, g, b].map(decode)
        // Rec.2020 primaries to Rec.709.
        var c = [
            1.6605 * lin[0] - 0.5876 * lin[1] - 0.0728 * lin[2],
            -0.1246 * lin[0] + 1.1329 * lin[1] - 0.0083 * lin[2],
            -0.0182 * lin[0] - 0.1006 * lin[1] + 1.1187 * lin[2],
        ].map { max(0, $0) }
        // Brighter than white rolls off smoothly instead of clipping; scaling all three channels
        // together keeps the hue.
        let peak = c.max() ?? 0
        if peak > Self.knee {
            let k = Self.knee
            let eased = k + (1 - k) * (1 - exp(-(peak - k) / (1 - k)))
            c = c.map { $0 * eased / peak }
        }
        let e = c.map(Self.rec709)
        return (e[0], e[1], e[2])
    }

    private static let knee = 0.9

    private func decode(_ v: Double) -> Double {
        switch self {
        case .standard:
            return v
        case .hlg:
            // Inverse HLG curve; HLG puts diffuse white at 75% (scene light 0.2647, BT.2408).
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            let e = v <= 0.5 ? v * v / 3 : (exp((v - c) / a) + b) / 12
            return e / 0.2647
        case .pq:
            // PQ to nits, with 203 nits as white (BT.2408).
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            let p = pow(max(0, v), 1 / m2)
            let y = pow(max(0, p - c1) / (c2 - c3 * p), 1 / m1)
            return y * 10000 / 203
        case .appleLog:
            // Apple Log to scene light (18% grey = 0.18), from Apple's published curve.
            let R0 = -0.05641088, Rt = 0.01, c = 47.28711236, b = 0.00964052, g = 0.08550479, be = 0.69336945
            let Pt = c * (Rt - R0) * (Rt - R0)
            if v >= Pt { return pow(2, (v - be) / g) - b }
            if v > 0 { return (v / c).squareRoot() + R0 }
            return R0
        }
    }

    private static func rec709(_ x: Double) -> Double {
        let v = min(1, max(0, x))
        return v < 0.018 ? 4.5 * v : 1.099 * pow(v, 0.45) - 0.099
    }
}

// MARK: - Frame grabs

/// Hands out single frames as images: library tiles, filmstrips and hover previews.
protocol FrameGrabber: AnyObject {
    func generateCGImageAsynchronously(for requestedTime: CMTime,
                                       completionHandler handler: @escaping @Sendable (CGImage?, CMTime, (any Error)?) -> Void)
    func cancelAllCGImageGeneration()
}

extension AVAssetImageGenerator: FrameGrabber {}

/// Frames from HDR and Log files, converted to Rec.709 exactly as playback does. The system's own
/// frame grabber converts these colours differently from playback, so this reads the frame itself.
final class ColorFrameGrabber: FrameGrabber, @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let orientation: CGImagePropertyOrientation
    private let color: SourceColor
    private let maximumSize: CGSize
    private let queue = DispatchQueue(label: "editroom.grab", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0

    init(asset: AVAsset, track: AVAssetTrack, naturalSize: CGSize, orientation: CGImagePropertyOrientation,
         color: SourceColor, maximumSize: CGSize) {
        self.asset = asset
        self.track = track
        self.orientation = orientation
        self.color = color
        self.maximumSize = maximumSize
    }

    func cancelAllCGImageGeneration() {
        lock.lock(); generation += 1; lock.unlock()
    }

    func generateCGImageAsynchronously(for requestedTime: CMTime,
                                       completionHandler handler: @escaping @Sendable (CGImage?, CMTime, (any Error)?) -> Void) {
        lock.lock(); let asked = generation; lock.unlock()
        queue.async { [self] in
            lock.lock(); let stale = asked != generation; lock.unlock()
            if stale { return handler(nil, requestedTime, nil) }
            let (image, time) = grab(requestedTime)
            handler(image, time, nil)
        }
    }

    /// The colour space macOS gives Rec.709 video, so these frames look like ordinary video frames.
    private static let videoSpace: CGColorSpace = {
        let tags = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary
        return CVImageBufferCreateColorSpaceFromAttachments(tags)?.takeRetainedValue() ?? CGColorSpace(name: CGColorSpace.itur_709)!
    }()

    private func grab(_ t: CMTime) -> (CGImage?, CMTime) {
        guard let reader = try? AVAssetReader(asset: asset) else { return (nil, t) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return (nil, t) }
        reader.add(output)
        let start = CMTimeMaximum(.zero, CMTimeMinimum(t, track.timeRange.end - CMTime(value: 1, timescale: 60)))
        reader.timeRange = CMTimeRange(start: start, duration: CMTime(value: 1, timescale: 2))
        defer { reader.cancelReading() }
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return (nil, t) }
        var image = CIImage(cvPixelBuffer: buffer)
        if orientation != .up { image = image.oriented(orientation) }
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return (nil, t) }
        let s = min(1, maximumSize.width / e.width, maximumSize.height / e.height)
        image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).scaledBy(x: 1, y: 1)
            .concatenating(CGAffineTransform(scaleX: s, y: s)))
        image = color.toRec709(image)
        let rect = CGRect(x: 0, y: 0, width: (e.width * s).rounded(), height: (e.height * s).rounded())
        let cg = TimelineCompositor.context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: Self.videoSpace)
        return (cg, CMSampleBufferGetPresentationTimeStamp(sample))
    }
}
