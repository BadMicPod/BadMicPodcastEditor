import AVFoundation
import AppKit
import CoreImage

struct BuiltTimeline {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let duration: Double
    let signature: Int
    let hasAudio: Bool
}

/// A tiny black movie stretched under everything so the composition always has video to drive rendering.
enum BaseVideo {
    static var track: AVAssetTrack?
    static var range = CMTimeRange.zero
    private static var asset: AVURLAsset?

    static func load() async {
        guard track == nil, let url = Bundle.main.url(forResource: "Base", withExtension: "mp4") else { return }
        let a = AVURLAsset(url: url)
        guard let t = try? await a.loadTracks(withMediaType: .video).first,
              let r = try? await t.load(.timeRange) else { return }
        asset = a
        range = r
        track = t
    }
}

enum CompositionBuilder {
    static let timescale: CMTimeScale = 60000

    static func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    static func frameDuration(fps: Double) -> CMTime {
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.001 { return CMTime(value: 1, timescale: CMTimeScale(rounded)) }
        // NTSC style rates: 23.976, 29.97, 59.94
        return CMTime(value: 1001, timescale: CMTimeScale((fps * 1.001).rounded()) * 1000)
    }

    static func previewSize(for project: Project) -> CGSize {
        let w = Double(project.width), h = Double(project.height)
        let s = min(1, 1920 / max(w, h))
        return CGSize(width: max(2, (w * s / 2).rounded() * 2), height: max(2, (h * s / 2).rounded() * 2))
    }

    @MainActor
    static func build(project: Project, media: MediaStore, renderSize: CGSize,
                      includeVideo: Bool = true, includeAudio: Bool = true) -> BuiltTimeline? {
        let total = project.duration
        guard total > 0 else { return nil }
        let comp = AVMutableComposition()
        var hasher = Hasher()
        hasher.combine(Int(renderSize.width)); hasher.combine(Int(renderSize.height))
        hasher.combine(project.fps); hasher.combine(time(total).value)
        hasher.combine(includeVideo); hasher.combine(includeAudio)

        if let base = BaseVideo.track, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? t.insertTimeRange(BaseVideo.range, of: base, at: .zero)
            t.scaleTimeRange(CMTimeRange(start: .zero, duration: BaseVideo.range.duration), toDuration: time(total))
            hasher.combine(1)
        }

        // Video
        var layers: [RenderLayer] = []
        var requiredTracks: [CMPersistentTrackID] = []
        let frame = CGRect(origin: .zero, size: renderSize)

        if includeVideo {
            for track in project.videoTracks where !track.hidden {
                hasher.combine(track.id)
                let clips = project.clips.filter { $0.trackID == track.id }.sorted { $0.start < $1.start }
                var compTrack: AVMutableCompositionTrack?
                var cursor = CMTime.zero
                for clip in clips {
                    switch clip.kind {
                    case .video:
                        guard let id = clip.assetID, let rt = media.runtimes[id], let src = rt.videoTrack else { continue }
                        if compTrack == nil {
                            compTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                            if let ct = compTrack { requiredTracks.append(ct.trackID) }
                        }
                        guard let ct = compTrack, insert(clip, source: src, range: rt.videoRange, into: ct, cursor: &cursor) else { continue }
                        hash(clip, into: &hasher)
                        layers.append(RenderLayer(clip: clip, source: .track(ct.trackID, rt.orientation)))
                    case .image:
                        guard let cg = media.still(clip.assetID) else { continue }
                        let img = CIImage(cgImage: cg)
                        let e = img.extent
                        let s = min(frame.width / e.width, frame.height / e.height)
                        let fitted = img.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                                                           tx: (frame.width - e.width * s) / 2,
                                                                           ty: (frame.height - e.height * s) / 2))
                        layers.append(RenderLayer(clip: clip, source: .image(fitted)))
                    case .solid:
                        let c = clip.color
                        layers.append(RenderLayer(clip: clip, source: .color(CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a))))
                    case .text:
                        guard let img = TextRenderer.image(clip.text, renderSize: renderSize) else { continue }
                        layers.append(RenderLayer(clip: clip, source: .image(img)))
                    case .audio:
                        continue
                    }
                }
            }
        }

        // Audio
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if includeAudio {
            for track in project.audioTracks where !track.muted {
                hasher.combine(track.id)
                let clips = project.clips.filter { $0.trackID == track.id && $0.kind == .audio }.sorted { $0.start < $1.start }
                var compTrack: AVMutableCompositionTrack?
                var params: AVMutableAudioMixInputParameters?
                var cursor = CMTime.zero
                let trackGain = dbToLinear(track.gainDB)
                for clip in clips {
                    guard clip.speed <= 32, clip.speed >= 1.0 / 32,
                          let id = clip.assetID, let rt = media.runtimes[id], let src = rt.audioTrack else { continue }
                    if compTrack == nil {
                        compTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        if let ct = compTrack {
                            let p = AVMutableAudioMixInputParameters(track: ct)
                            p.audioTimePitchAlgorithm = .spectral
                            params = p
                            mixParams.append(p)
                        }
                    }
                    guard let ct = compTrack, let p = params, insert(clip, source: src, range: rt.audioRange, into: ct, cursor: &cursor) else { continue }
                    hash(clip, into: &hasher)

                    let gain = Float(trackGain * dbToLinear(clip.gainDB))
                    let start = time(clip.start), end = time(clip.end)
                    let fi = min(time(clip.fadeIn), end - start)
                    let fo = min(time(clip.fadeOut), end - start - fi)
                    if fi > .zero {
                        ramp(p, from: start, duration: fi, gain: gain, curve: clip.inCurve, rising: true)
                    } else {
                        p.setVolume(gain, at: start)
                    }
                    if fo > .zero {
                        ramp(p, from: end - fo, duration: fo, gain: gain, curve: clip.outCurve, rising: false)
                    }
                }
            }
        }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = TimelineCompositor.self
        vc.frameDuration = frameDuration(fps: project.fps)
        vc.renderSize = renderSize
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let range = CMTimeRange(start: .zero, duration: CMTimeMaximum(comp.duration, time(total)))
        vc.instructions = [TimelineInstruction(timeRange: range, layers: layers, trackIDs: requiredTracks)]

        var mix: AVMutableAudioMix?
        if !mixParams.isEmpty {
            mix = AVMutableAudioMix()
            mix?.inputParameters = mixParams
        }

        return BuiltTimeline(composition: comp.copy() as! AVComposition, videoComposition: vc, audioMix: mix,
                             duration: total, signature: hasher.finalize(), hasAudio: !mixParams.isEmpty)
    }

    /// Volume ramps are linear, so curved fades are approximated with short linear pieces.
    private static func ramp(_ p: AVMutableAudioMixInputParameters, from start: CMTime, duration: CMTime,
                             gain: Float, curve: FadeCurve, rising: Bool) {
        let pieces = curve == .linear ? 1 : 16
        var t0 = start
        for i in 0..<pieces {
            let x0 = Double(i) / Double(pieces), x1 = Double(i + 1) / Double(pieces)
            let t1 = i == pieces - 1 ? start + duration : start + CMTimeMultiplyByFloat64(duration, multiplier: x1)
            guard t1 > t0 else { continue }
            let v0 = gain * Float(curve.apply(rising ? x0 : 1 - x0))
            let v1 = gain * Float(curve.apply(rising ? x1 : 1 - x1))
            p.setVolumeRamp(fromStartVolume: v0, toEndVolume: v1, timeRange: CMTimeRange(start: t0, end: t1))
            t0 = t1
        }
    }

    private static func hash(_ clip: Clip, into hasher: inout Hasher) {
        hasher.combine(clip.assetID)
        hasher.combine(clip.start)
        hasher.combine(clip.duration)
        hasher.combine(clip.sourceStart)
        hasher.combine(clip.speed)
    }

    /// Places one clip's media on a composition track, applying speed by scaling the inserted range.
    private static func insert(_ clip: Clip, source: AVAssetTrack, range: CMTimeRange,
                               into track: AVMutableCompositionTrack, cursor: inout CMTime) -> Bool {
        let start = time(clip.start)
        let end = time(clip.end)
        guard start >= cursor, end > start else { return false }
        let unity = abs(clip.speed - 1) < 1e-9
        var srcStart = time(clip.sourceStart)
        var tgtDur = end - start
        var srcDur = unity ? tgtDur : time(clip.duration * clip.speed)
        if srcStart < range.start { srcStart = range.start }
        let available = range.end - srcStart
        guard available > .zero else { return false }
        if srcDur > available {
            srcDur = available
            tgtDur = unity ? available : CMTimeMinimum(tgtDur, CMTimeMultiplyByFloat64(available, multiplier: 1 / clip.speed))
        }
        guard srcDur > .zero, tgtDur > .zero else { return false }
        do {
            try track.insertTimeRange(CMTimeRange(start: srcStart, duration: srcDur), of: source, at: start)
        } catch {
            return false
        }
        if srcDur != tgtDur {
            track.scaleTimeRange(CMTimeRange(start: start, duration: srcDur), toDuration: tgtDur)
        }
        cursor = start + tgtDur
        return true
    }
}

// MARK: - Text

enum TextRenderer {
    private struct Key: Hashable {
        let style: TextStyle
        let w: Int
        let h: Int
    }

    @MainActor private static var cache: [Key: CIImage] = [:]

    static func font(_ style: TextStyle, size: CGFloat) -> NSFont {
        if !style.fontName.isEmpty {
            let manager = NSFontManager.shared
            if let f = manager.font(withFamily: style.fontName, traits: style.bold ? .boldFontMask : [], weight: 5, size: size) { return f }
            if let f = NSFont(name: style.fontName, size: size) { return f }
        }
        return NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
    }

    @MainActor
    static func image(_ style: TextStyle, renderSize: CGSize) -> CIImage? {
        guard !style.string.isEmpty else { return nil }
        let key = Key(style: style, w: Int(renderSize.width), h: Int(renderSize.height))
        if let hit = cache[key] { return hit }

        let pt = CGFloat(style.size) * renderSize.height / 1080
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let c = style.color
        let attr = NSAttributedString(string: style.string, attributes: [
            .font: font(style, size: pt),
            .foregroundColor: NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a),
            .paragraphStyle: para,
        ])
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let bounds = attr.boundingRect(with: CGSize(width: renderSize.width * 0.94, height: .greatestFiniteMagnitude), options: opts)
        let pad = ceil(pt * 0.25)
        let tw = ceil(bounds.width), th = ceil(bounds.height)
        let w = Int(tw + pad * 2), h = Int(th + pad * 2)
        guard w > 0, h > 0, w < 16384, h < 16384,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attr.draw(with: CGRect(x: pad, y: pad, width: tw, height: th), options: opts)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }

        let cx = style.x * renderSize.width
        let cy = (1 - style.y) * renderSize.height
        let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(
            translationX: (cx - CGFloat(w) / 2).rounded(), y: (cy - CGFloat(h) / 2).rounded()))
        if cache.count > 64 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
