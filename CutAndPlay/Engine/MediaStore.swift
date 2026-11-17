import AVFoundation
import AppKit
import UniformTypeIdentifiers
import ImageIO

/// Loaded AVFoundation objects for one imported file.
final class MediaRuntime {
    let asset: AVURLAsset
    var videoTrack: AVAssetTrack?
    var audioTrack: AVAssetTrack?
    var videoRange = CMTimeRange.zero
    var audioRange = CMTimeRange.zero
    var orientation = CGImagePropertyOrientation.up
    var generator: AVAssetImageGenerator?

    init(asset: AVURLAsset) { self.asset = asset }
}

struct Waveform {
    let peaksPerSecond: Double
    let peaks: [Float]
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

    func forget(_ id: UUID) {
        runtimes[id] = nil
        posters[id] = nil
        waveforms[id] = nil
        stills[id] = nil
        thumbs = thumbs.filter { $0.key.asset != id }
    }

    private func adopt(_ rt: MediaRuntime, for asset: MediaAsset) {
        runtimes[asset.id] = rt
        if rt.videoTrack != nil {
            let gen = AVAssetImageGenerator(asset: rt.asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 120)
            rt.generator = gen
            makePoster(asset, rt)
        }
        if rt.audioTrack != nil { makeWaveform(asset.id, rt) }
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
                let rect = CGRect(origin: .zero, size: size).applying(tf)
                info.width = Int(abs(rect.width).rounded())
                info.height = Int(abs(rect.height).rounded())
                info.fps = Double(rate)
                rt.orientation = orientation(for: tf)
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
        let gen = AVAssetImageGenerator(asset: rt.asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
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

    // MARK: Waveforms

    private func makeWaveform(_ id: UUID, _ rt: MediaRuntime) {
        guard let track = rt.audioTrack, !waveformJobs.contains(id) else { return }
        waveformJobs.insert(id)
        let asset = rt.asset
        Task.detached(priority: .utility) {
            let wf = WaveformReader.read(asset: asset, track: track)
            await MainActor.run { [weak self] in
                self?.waveformJobs.remove(id)
                if let wf { self?.waveforms[id] = wf }
                self?.notifyVisual()
            }
        }
    }
}

// MARK: - Waveform extraction

enum WaveformReader {
    static func read(asset: AVAsset, track: AVAssetTrack, peaksPerSecond: Double = 200) -> Waveform? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var peaks: [Float] = []
        var bucketPeak: Int32 = 0
        var bucketFill = 0.0
        var framesPerBucket = 0.0
        var scratch = [Int16]()

        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample),
                  let fmt = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { continue }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            framesPerBucket = asbd.mSampleRate / peaksPerSecond
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Int16>.size
            if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
            scratch.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: raw.baseAddress!)
            }
            scratch.withUnsafeBufferPointer { buf in
                var i = 0
                while i + channels <= count {
                    var m: Int32 = 0
                    for ch in 0..<channels {
                        let v = abs(Int32(buf[i + ch]))
                        if v > m { m = v }
                    }
                    if m > bucketPeak { bucketPeak = m }
                    bucketFill += 1
                    if bucketFill >= framesPerBucket {
                        peaks.append(Float(bucketPeak) / 32768)
                        bucketPeak = 0
                        bucketFill -= framesPerBucket
                    }
                    i += channels
                }
            }
        }
        guard !peaks.isEmpty else { return nil }
        return Waveform(peaksPerSecond: peaksPerSecond, peaks: peaks)
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
            .appendingPathComponent("CutAndPlay/Converted", isDirectory: true)
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
