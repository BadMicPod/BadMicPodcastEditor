import AVFoundation
import AppKit
import UniformTypeIdentifiers
import ImageIO
import Accelerate

/// Loaded AVFoundation objects for one imported file.
final class MediaRuntime {
    let asset: AVURLAsset
    var videoTrack: AVAssetTrack?
    var audioTrack: AVAssetTrack?
    var videoRange = CMTimeRange.zero
    var audioRange = CMTimeRange.zero
    var orientation = CGImagePropertyOrientation.up
    var naturalSize = CGSize.zero
    /// How the picture is encoded: standard, HDR or Log.
    var sourceColor = SourceColor.standard
    /// The file's sound played backwards, once it's been made.
    var reversedAudio: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)?
    /// Frames for playing the picture backwards.
    lazy var reverseFrames: ReverseFrames? = videoTrack.map {
        ReverseFrames(asset: asset, track: $0, naturalSize: naturalSize, tenBit: !sourceColor.isStandard)
    }
    var generator: FrameGrabber?
    /// Frames for hover-scrubbing a library tile: closer to the asked-for time than the filmstrip's.
    lazy var scrubGenerator: FrameGrabber = makeGenerator(maximumSize: CGSize(width: 400, height: 240),
                                                          tolerance: CMTime(value: 1, timescale: 10))

    /// Full-size frames for showing a library item in the main viewer while hover-scrubbing it.
    lazy var viewerGenerator: FrameGrabber = makeGenerator(maximumSize: CGSize(width: 1920, height: 1920),
                                                           tolerance: CMTime(value: 1, timescale: 30))

    init(asset: AVURLAsset) { self.asset = asset }

    /// A frame grabber for this file. HDR and Log frames are converted the same way as in playback,
    /// so library tiles, filmstrips and hover previews look like the timeline.
    func makeGenerator(maximumSize: CGSize, tolerance: CMTime? = nil) -> FrameGrabber {
        if !sourceColor.isStandard, let track = videoTrack {
            return ColorFrameGrabber(asset: asset, track: track, naturalSize: naturalSize, orientation: orientation,
                                     color: sourceColor, maximumSize: maximumSize)
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maximumSize
        if let tolerance {
            gen.requestedTimeToleranceBefore = tolerance
            gen.requestedTimeToleranceAfter = tolerance
        }
        return gen
    }
}

struct Waveform {
    let peaksPerSecond: Double
    /// Loudest of all channels, for drawing.
    let peaks: [Float]
    /// The first two channels on their own, for left and right meters (the same for mono).
    let left: [Float]
    let right: [Float]
    /// Average loudness (RMS) of each stretch, for drawing: shows the shape of dense music
    /// better than the very top of each peak.
    let rms: [Float]
}

struct ThumbKey: Hashable {
    let asset: UUID
    let ms: Int
}

@MainActor
final class MediaStore: ObservableObject {
    private(set) var runtimes: [UUID: MediaRuntime] = [:]
    @Published private(set) var posters: [UUID: NSImage] = [:]
    private(set) var waveforms: [UUID: Waveform] = [:]
    private var thumbs: [ThumbKey: CGImage] = [:]
    private var pendingThumbs = Set<ThumbKey>()
    private var stills: [UUID: CGImage] = [:]
    private var waveformJobs = Set<UUID>()
    private var reversedWaveforms: [UUID: Waveform] = [:]
    private var reverseJobs: [UUID: Task<Void, Never>] = [:]
    /// Frames made ahead for hover-scrubbing Media items.
    private let strips = ScrubStrips()
    /// Called when a file's reversed sound is ready, so the timeline can be rebuilt with it.
    var onReverseReady: (() -> Void)?

    /// Called (coalesced) when thumbnails or waveforms arrive so the timeline can redraw.
    var onVisualUpdate: (() -> Void)?
    private var visualUpdateScheduled = false

    private func notifyVisual() {
        guard !visualUpdateScheduled else { return }
        visualUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.visualUpdateScheduled = false
                self?.onVisualUpdate?()
            }
        }
    }

    // MARK: Import

    /// Probes a file and returns a library asset, converting through ffmpeg when AVFoundation can't read it.
    /// Pass `replacing` to point an existing library item at a new file: it keeps its identity and
    /// name, so every clip made from it follows. The new file must be the same kind of media.
    func importFile(_ url: URL, replacing old: MediaAsset? = nil) async -> MediaAsset? {
        let name = old?.name ?? url.deletingPathExtension().lastPathComponent
        let id = old?.id ?? UUID()
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
            var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let o = props[kCGImagePropertyOrientation] as? UInt32, o >= 5 { swap(&w, &h) }
            guard w > 0, h > 0 else { return nil }
            if let old, old.kind != .image { return nil }
            let asset = MediaAsset(id: id, path: url.path, name: name, kind: .image, duration: 0, width: w, height: h, fps: 0, hasAudio: false)
            forget(id)
            loadStill(asset)
            return asset
        }

        var playable: String?
        var probed = await Self.probe(url)
        if probed == nil, let converted = await FFmpeg.makePlayable(url) {
            probed = await Self.probe(converted)
            playable = converted.path
        }
        guard let (rt, info) = probed else { return nil }
        if let old, old.kind != (rt.videoTrack != nil ? .video : .audio) { return nil }
        forget(id)
        let asset = MediaAsset(id: id, path: url.path, playablePath: playable, name: name,
                               kind: rt.videoTrack != nil ? .video : .audio,
                               duration: info.duration, width: info.width, height: info.height,
                               fps: info.fps, hasAudio: rt.audioTrack != nil)
        adopt(rt, for: asset)
        return asset
    }

    /// Re-attaches runtimes for assets coming from a saved project. When a converted copy has gone
    /// but its original is still there, the original is converted again; the new copies' paths are
    /// returned by asset id so the project can be updated.
    func restore(_ assets: [MediaAsset]) async -> [UUID: String] {
        var reconverted: [UUID: String] = [:]
        for var a in assets where runtimes[a.id] == nil {
            if a.kind == .image { loadStill(a); continue }
            if let playable = a.playablePath, !FileManager.default.fileExists(atPath: playable),
               FileManager.default.fileExists(atPath: a.path),
               let again = await FFmpeg.makePlayable(URL(fileURLWithPath: a.path)) {
                a.playablePath = again.path
                reconverted[a.id] = again.path
            }
            guard FileManager.default.fileExists(atPath: a.url.path),
                  let (rt, _) = await Self.probe(a.url) else { continue }
            adopt(rt, for: a)
        }
        return reconverted
    }

    func isOffline(_ asset: MediaAsset) -> Bool {
        asset.kind == .image ? stills[asset.id] == nil : runtimes[asset.id] == nil
    }

    private var tagURLs: [UUID: URL] = [:]

    /// What a library item shows ("pool", "beach"), once it's been seen.
    func sceneTags(_ id: UUID) -> SceneTags? { tagURLs[id].flatMap { SceneTagStore.shared.tags(for: $0) } }

    /// The file a library item's sound is read from (its converted copy, if it has one).
    func soundURL(_ id: UUID) -> URL? { runtimes[id]?.audioTrack != nil ? runtimes[id]?.asset.url : nil }

    /// What's said in a library item, if it's been heard yet.
    func transcript(_ id: UUID) -> Transcript? { soundURL(id).flatMap { Transcripts.shared.transcript(for: $0) } }

    func forget(_ id: UUID) {
        runtimes[id] = nil
        posters[id] = nil
        waveforms[id] = nil
        reversedWaveforms[id] = nil
        stills[id] = nil
        thumbs = thumbs.filter { $0.key.asset != id }
        strips.forget(id)
    }

    private func adopt(_ rt: MediaRuntime, for asset: MediaAsset) {
        runtimes[asset.id] = rt
        if rt.videoTrack != nil {
            let gen = rt.makeGenerator(maximumSize: CGSize(width: 320, height: 120))
            rt.generator = gen
            makePoster(asset, rt)
            // What it shows, for Media search and Magic: once, in the background.
            tagURLs[asset.id] = rt.asset.url
            SceneTagStore.shared.make(rt.asset.url, isVideo: true, duration: asset.duration)
            // Its best moments, as Magic scores them: ready before Magic needs them.
            AnalysisWarmer.shared.warm(asset.url, kind: asset.kind, song: false)
            strips.make(asset.id, rt, duration: asset.duration)
        }
        if rt.audioTrack != nil {
            makeWaveform(asset.id, rt)
            // A song (sound only, 8 seconds or more): its tempo and beats, ready for Magic.
            if rt.videoTrack == nil, asset.duration >= 8 { AnalysisWarmer.shared.warm(asset.url, kind: asset.kind, song: true) }
            // What's said in it, for Magic and Media search: made once, in the background.
            Transcripts.shared.make(rt.asset.url)
        }
    }

    struct ProbeInfo {
        var duration = 0.0, width = 0, height = 0, fps = 0.0
    }

    nonisolated static func probe(_ url: URL) async -> (MediaRuntime, ProbeInfo)? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let (tracks, playable) = try? await asset.load(.tracks, .isPlayable), playable else { return nil }
        let rt = MediaRuntime(asset: asset)
        var info = ProbeInfo()
        for t in tracks {
            if t.mediaType == .video, rt.videoTrack == nil {
                guard let (decodable, size, tf, rate, range) = try? await t.load(.isDecodable, .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange),
                      decodable, size.width > 0, range.duration.seconds > 0 else { continue }
                rt.videoTrack = t
                rt.videoRange = range
                rt.naturalSize = size
                let rect = CGRect(origin: .zero, size: size).applying(tf)
                info.width = Int(abs(rect.width).rounded())
                info.height = Int(abs(rect.height).rounded())
                info.fps = Double(rate)
                rt.orientation = orientation(for: tf)
                rt.sourceColor = SourceColor.of(t)
            } else if t.mediaType == .audio, rt.audioTrack == nil {
                guard let (decodable, range) = try? await t.load(.isDecodable, .timeRange),
                      decodable, range.duration.seconds > 0 else { continue }
                rt.audioTrack = t
                rt.audioRange = range
            }
        }
        guard rt.videoTrack != nil || rt.audioTrack != nil else { return nil }
        // A file whose video stream can't be decoded should go through conversion rather than import as audio.
        if rt.videoTrack == nil, tracks.contains(where: { $0.mediaType == .video }) { return nil }
        info.duration = max(rt.videoRange.end.seconds, rt.audioRange.end.seconds)
        if rt.videoTrack != nil { info.duration = rt.videoRange.end.seconds }
        guard info.duration.isFinite, info.duration > 0 else { return nil }
        return (rt, info)
    }

    nonisolated static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        if abs(t.a) < 0.5 {
            return t.b > 0 ? .right : .left
        }
        return t.a < 0 ? .down : .up
    }

    // MARK: Posters & stills

    private func makePoster(_ asset: MediaAsset, _ rt: MediaRuntime) {
        let gen = rt.makeGenerator(maximumSize: CGSize(width: 480, height: 480))
        let t = CMTime(seconds: min(1, asset.duration * 0.1), preferredTimescale: 600)
        let id = asset.id
        gen.generateCGImageAsynchronously(for: t) { [weak self] cg, _, _ in
            guard let cg else { return }
            Task { @MainActor in
                self?.posters[id] = NSImage(cgImage: cg, size: .zero)
            }
        }
    }

    private func loadStill(_ asset: MediaAsset) {
        let url = asset.url
        let id = asset.id
        tagURLs[id] = url
        SceneTagStore.shared.make(url, isVideo: false, duration: 0)
        AnalysisWarmer.shared.warm(url, kind: .image, song: false)
        Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3840,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            await MainActor.run { [weak self] in
                self?.stills[id] = cg
                self?.posters[id] = NSImage(cgImage: cg, size: .zero)
                self?.onStillLoaded?()
                self?.notifyVisual()
            }
        }
    }

    var onStillLoaded: (() -> Void)?

    func still(_ id: UUID?) -> CGImage? {
        guard let id else { return nil }
        return stills[id]
    }

    // MARK: Timeline thumbnails

    /// Returns a cached filmstrip thumbnail, kicking off generation when missing.
    func thumbnail(asset id: UUID, time: Double) -> CGImage? {
        let key = ThumbKey(asset: id, ms: Int((time * 1000).rounded()))
        if let img = thumbs[key] { return img }
        guard !pendingThumbs.contains(key), let gen = runtimes[id]?.generator else { return nil }
        pendingThumbs.insert(key)
        gen.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] cg, _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingThumbs.remove(key)
                guard let cg else { return }
                if self.thumbs.count > 1500 { self.thumbs.removeAll() }
                self.thumbs[key] = cg
                self.notifyVisual()
            }
        }
        return nil
    }

    /// A timeline thumbnail only if it's already made (asks for nothing).
    func cachedThumbnail(asset id: UUID, time: Double) -> CGImage? {
        thumbs[ThumbKey(asset: id, ms: Int((time * 1000).rounded()))]
    }

    private var scrubFrames: [ThumbKey: CGImage] = [:]

    /// A hover-scrub frame made ahead, at once: the nearest to a point across the item (0 to 1). Nil
    /// until its strip is made; asking moves it to the front of the line.
    func instantFrame(asset: MediaAsset, at fraction: Double) -> CGImage? {
        if let img = strips.frame(asset.id, at: fraction) { return img }
        if let rt = runtimes[asset.id] { strips.make(asset.id, rt, duration: asset.duration, soon: true) }
        return nil
    }

    /// A frame for hover-scrubbing a library tile. Cached frames come back at once; otherwise any
    /// earlier request still in flight is dropped, so the frame keeps up with the mouse.
    func scrubFrame(asset id: UUID, time: Double, completion: @escaping (CGImage) -> Void) {
        let key = ThumbKey(asset: id, ms: Int((time * 1000).rounded()))
        if let img = scrubFrames[key] { return completion(img) }
        guard let rt = runtimes[id], rt.videoTrack != nil else { return }
        let gen = rt.scrubGenerator
        gen.cancelAllCGImageGeneration()
        gen.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] cg, _, _ in
            guard let cg else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.scrubFrames.count > 600 { self.scrubFrames.removeAll() }
                self.scrubFrames[key] = cg
                completion(cg)
            }
        }
    }

    /// A full-size frame for the main viewer. Any earlier request still in flight is dropped.
    func viewerFrame(asset id: UUID, time: Double, completion: @escaping (CGImage) -> Void) {
        guard let rt = runtimes[id], rt.videoTrack != nil else { return }
        let gen = rt.viewerGenerator
        gen.cancelAllCGImageGeneration()
        gen.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 600)) { cg, _, _ in
            guard let cg else { return }
            Task { @MainActor in completion(cg) }
        }
    }

    // MARK: Reversed sound

    /// A file's reversed sound, if it's ready. If it isn't, it starts being made (`onReverseReady`
    /// says when it's done).
    func reversedAudio(_ id: UUID) -> (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)? {
        if let r = runtimes[id]?.reversedAudio { return r }
        _ = prepareReversedAudio(id)
        return nil
    }

    @discardableResult
    func prepareReversedAudio(_ id: UUID) -> Task<Void, Never>? {
        guard let rt = runtimes[id], rt.reversedAudio == nil, let track = rt.audioTrack else { return nil }
        if let job = reverseJobs[id] { return job }
        let asset = rt.asset
        let out = ReverseAudio.cacheURL(for: asset.url)
        let job = Task { [weak self] in
            let ready: Bool = await Task.detached(priority: .userInitiated) {
                if FileManager.default.fileExists(atPath: out.path) { return true }
                do { try ReverseAudio.render(asset: asset, track: track, to: out); return true } catch { return false }
            }.value
            let file = AVURLAsset(url: out, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var loaded: (AVAssetTrack, CMTimeRange)?
            if ready, let t = try? await file.loadTracks(withMediaType: .audio).first, let r = try? await t.load(.timeRange) { loaded = (t, r) }
            guard let self else { return }
            self.reverseJobs[id] = nil
            if let (t, r) = loaded, let rt = self.runtimes[id] {
                rt.reversedAudio = (file, t, r)
                self.onReverseReady?()
            }
        }
        reverseJobs[id] = job
        return job
    }

    /// Waits until every reversed clip's sound is ready (before exporting).
    func prepareReversedAudio(for project: Project) async {
        let ids = Set(project.clips.filter { $0.kind == .audio && $0.playsBackwards }.compactMap(\.assetID))
        for id in ids { await prepareReversedAudio(id)?.value }
    }

    func needsReversedAudio(_ project: Project) -> Bool {
        project.clips.contains { c in
            guard c.kind == .audio, c.playsBackwards, let id = c.assetID, let rt = runtimes[id] else { return false }
            return rt.audioTrack != nil && rt.reversedAudio == nil
        }
    }

    // MARK: Waveforms

    /// The waveform the way a clip plays it: mirrored for a reversed clip.
    func waveform(_ c: Clip) -> Waveform? {
        guard let id = c.assetID, let wf = waveforms[id] else { return nil }
        guard c.playsBackwards else { return wf }
        if let r = reversedWaveforms[id] { return r }
        let r = Waveform(peaksPerSecond: wf.peaksPerSecond, peaks: wf.peaks.reversed(), left: wf.left.reversed(), right: wf.right.reversed(), rms: wf.rms.reversed())
        reversedWaveforms[id] = r
        return r
    }

    private func makeWaveform(_ id: UUID, _ rt: MediaRuntime) {
        guard let track = rt.audioTrack, !waveformJobs.contains(id) else { return }
        waveformJobs.insert(id)
        let asset = rt.asset
        Task.detached(priority: .userInitiated) {
            // Made once per file and kept on disk, so reopening a project shows waveforms at once.
            let cache = WaveformReader.cacheURL(for: asset.url)
            var wf = WaveformReader.load(cache)
            if wf == nil {
                wf = WaveformReader.read(asset: asset, track: track)
                if let wf { WaveformReader.save(wf, to: cache) }
            }
            await MainActor.run { [weak self] in
                self?.waveformJobs.remove(id)
                if let wf { self?.waveforms[id] = wf; self?.reversedWaveforms[id] = nil }
                self?.notifyVisual()
            }
        }
    }
}

// MARK: - Waveform extraction

enum WaveformReader {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(for source: URL) -> URL {
        folder.appendingPathComponent(ReverseAudio.cacheName(for: source) + ".wave")
    }

    // MARK: Cache file: "ERWF", version, peaks per second, count, then peaks, left, right, rms as Float32.

    private static let magic: UInt32 = 0x4657_5245 // "ERWF"
    private static let version: UInt32 = 1

    static func save(_ wf: Waveform, to url: URL) {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(magic); put(version); put(wf.peaksPerSecond); put(UInt32(wf.peaks.count))
        for arr in [wf.peaks, wf.left, wf.right, wf.rms] {
            guard arr.count == wf.peaks.count else { return }
            arr.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        try? d.write(to: url, options: .atomic)
    }

    static func load(_ url: URL) -> Waveform? {
        guard let d = try? Data(contentsOf: url), d.count >= 20 else { return nil }
        return d.withUnsafeBytes { raw -> Waveform? in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic,
                  raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == version else { return nil }
            let pps = raw.loadUnaligned(fromByteOffset: 8, as: Double.self)
            let n = Int(raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
            guard n > 0, d.count == 20 + n * 4 * 4 else { return nil }
            func array(_ k: Int) -> [Float] {
                [Float](unsafeUninitializedCapacity: n) { buf, count in
                    _ = memcpy(buf.baseAddress!, raw.baseAddress! + 20 + k * n * 4, n * 4)
                    count = n
                }
            }
            return Waveform(peaksPerSecond: pps, peaks: array(0), left: array(1), right: array(2), rms: array(3))
        }
    }

    // MARK: Reading

    /// Decodes the sound once and sums it into short stretches. The sums use Accelerate's vector
    /// routines, so they run at full speed whatever the build settings.
    static func read(asset: AVAsset, track: AVAssetTrack, peaksPerSecond: Double = 200) -> Waveform? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var peaks: [Float] = [], left: [Float] = [], right: [Float] = [], rms: [Float] = []
        // The stretch being filled, which can run across decoded buffers.
        var peak: Float = 0, l: Float = 0, r: Float = 0, squares: Float = 0, fill = 0.0
        var samples = [Float]()
        var loudest = [Float]()

        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample),
                  let fmt = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { continue }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let framesPerBucket = asbd.mSampleRate / peaksPerSecond
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            let frames = count / channels
            guard frames > 0 else { continue }
            if samples.count < count { samples = [Float](repeating: 0, count: count) }
            if loudest.count < frames { loudest = [Float](repeating: 0, count: frames) }
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: raw.baseAddress!)
            }
            samples.withUnsafeBufferPointer { s in
                loudest.withUnsafeMutableBufferPointer { m in
                    let src = s.baseAddress!, dst = m.baseAddress!
                    // Loudest channel of each frame.
                    vDSP_vabs(src, vDSP_Stride(channels), dst, 1, vDSP_Length(frames))
                    for ch in 1..<channels {
                        vDSP_vmaxmg(src + ch, vDSP_Stride(channels), dst, 1, dst, 1, vDSP_Length(frames))
                    }
                    let rightChannel = min(1, channels - 1)
                    var pos = 0
                    while pos < frames {
                        let need = max(1, Int((framesPerBucket - fill).rounded(.up)))
                        let take = min(need, frames - pos)
                        let n = vDSP_Length(take)
                        var v: Float = 0
                        vDSP_maxv(dst + pos, 1, &v, n); peak = max(peak, v)
                        vDSP_svesq(dst + pos, 1, &v, n); squares += v
                        vDSP_maxmgv(src + pos * channels, vDSP_Stride(channels), &v, n); l = max(l, v)
                        vDSP_maxmgv(src + pos * channels + rightChannel, vDSP_Stride(channels), &v, n); r = max(r, v)
                        fill += Double(take)
                        pos += take
                        if fill >= framesPerBucket - 1e-6 {
                            peaks.append(peak)
                            rms.append((squares / Float(max(1, fill))).squareRoot())
                            left.append(l)
                            right.append(r)
                            peak = 0; l = 0; r = 0; squares = 0
                            fill -= framesPerBucket
                        }
                    }
                }
            }
        }
        guard !peaks.isEmpty else { return nil }
        return Waveform(peaksPerSecond: peaksPerSecond, peaks: peaks, left: left, right: right, rms: rms)
    }
}

// MARK: - ffmpeg fallback

enum FFmpeg {
    static var binary: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Rewraps (or, failing that, transcodes) a file into something AVFoundation decodes.
    static func makePlayable(_ url: URL) async -> URL? {
        guard let bin = binary else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\(attrs?[.size] ?? 0)|\(attrs?[.modificationDate] ?? Date.distantPast)"
        // A hash that is the same on every launch, so re-converting a file reuses its copy's name.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in stamp.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let base = url.deletingPathExtension().lastPathComponent + "-" + String(hash, radix: 36)
        let out = cacheDir.appendingPathComponent(base + ".mov")

        // 1. Stream copy into a QuickTime container (instant for H.264/HEVC/AAC inside MKV etc).
        if await run(bin, ["-y", "-i", url.path, "-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy", "-tag:v", "hvc1", out.path]),
           await MediaStore.probe(out) != nil { return out }
        if await run(bin, ["-y", "-i", url.path, "-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy", out.path]),
           await MediaStore.probe(out) != nil { return out }
        // 2. Full transcode with the hardware encoder.
        if await run(bin, ["-y", "-i", url.path, "-map", "0:v:0?", "-map", "0:a:0?",
                           "-c:v", "h264_videotoolbox", "-q:v", "70", "-pix_fmt", "yuv420p",
                           "-c:a", "aac", "-b:a", "256k", out.path]),
           await MediaStore.probe(out) != nil { return out }
        try? FileManager.default.removeItem(at: out)
        return nil
    }

    private static func run(_ bin: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
            do { try p.run() } catch { cont.resume(returning: false) }
        }
    }
}
