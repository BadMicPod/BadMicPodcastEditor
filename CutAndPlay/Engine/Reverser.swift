import AVFoundation

/// Renders a stretch of a media file played backwards (picture and sound) into a new file, so a
/// reversed clip plays as smoothly as any other. Video is read half a second at a time from the end
/// and written frame by frame in reverse, so even long 4K clips only hold a few frames in memory.
enum Reverser {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CutAndPlay/Reversed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func render(source: URL, start: Double, duration: Double, to out: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        guard videoTrack != nil || audioTrack != nil else { throw Failure(message: "There's nothing to reverse in this file.") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var videoFile: URL?
        var transform = CGAffineTransform.identity
        if let videoTrack {
            let url = tmp.appendingPathComponent("v.mov")
            transform = try await videoTrack.load(.preferredTransform)
            do {
                try await reverseVideo(asset: asset, track: videoTrack, start: start, duration: duration, to: url) { p in
                    progress(p * (audioTrack == nil ? 1 : 0.9))
                }
            } catch { throw Failure(message: "the picture couldn't be reversed (\(error.localizedDescription))") }
            videoFile = url
        }
        var audioFile: URL?
        if let audioTrack {
            let url = tmp.appendingPathComponent("a.caf")
            do { try reverseAudio(asset: asset, track: audioTrack, start: start, duration: duration, to: url) } catch { throw Failure(message: "the sound couldn't be reversed (\(error.localizedDescription))") }
            audioFile = url
        }
        progress(0.95)

        // Put the two together in one file without re-encoding.
        let comp = AVMutableComposition()
        // Hold the files open while their tracks are copied in.
        let videoAsset = videoFile.map { AVURLAsset(url: $0) }
        let audioAsset = audioFile.map { AVURLAsset(url: $0) }
        let length = CMTime(seconds: duration, preferredTimescale: 600)
        do {
            if let videoAsset, let src = try await videoAsset.loadTracks(withMediaType: .video).first,
               let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = try await src.load(.timeRange)
                try t.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(range.duration, length)), of: src, at: .zero)
                t.preferredTransform = transform
            }
        } catch { throw Failure(message: "the reversed picture couldn't be put together (\(error.localizedDescription))") }
        do {
            if let audioAsset, let src = try await audioAsset.loadTracks(withMediaType: .audio).first,
               let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = try await src.load(.timeRange)
                try t.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(range.duration, length)), of: src, at: .zero)
            }
        } catch { throw Failure(message: "the reversed sound couldn't be put together (\(error.localizedDescription))") }
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure(message: "Couldn't write the reversed clip.")
        }
        do { try await export.export(to: out, as: .mov) } catch { throw Failure(message: "the reversed clip couldn't be saved (\(error.localizedDescription))") }
        progress(1)
    }

    private static func reverseVideo(asset: AVAsset, track: AVAssetTrack, start: Double, duration: Double, to url: URL,
                                     progress: (Double) -> Void) async throws {
        let (size, rate, frameDuration) = try await track.load(.naturalSize, .nominalFrameRate, .minFrameDuration)
        let fps = Double(rate > 1 ? rate : 30)
        let step = frameDuration.isValid && frameDuration.seconds > 0 ? frameDuration : CMTime(seconds: 1 / fps, preferredTimescale: 6000)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let w = Int(size.width), h = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: w * h > 2_500_000 ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(w * h) * fps * 0.22)],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw Failure(message: "Couldn't start writing the reversed clip.") }
        writer.startSession(atSourceTime: .zero)

        let chunk = 0.5
        let end = start + duration
        var chunkEnd = end
        var written: Int64 = 0
        while chunkEnd > start + 1e-6 {
            try Task.checkCancellation()
            let chunkStart = max(start, chunkEnd - chunk)
            guard let reader = try? AVAssetReader(asset: asset) else { throw Failure(message: "Couldn't read the clip.") }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: chunkStart, preferredTimescale: 6000),
                                           end: CMTime(seconds: chunkEnd, preferredTimescale: 6000))
            reader.startReading()
            var frames: [CVPixelBuffer] = []
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard pts >= chunkStart - 1e-4, pts < chunkEnd - 1e-4, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                frames.append(buffer)
            }
            for buffer in frames.reversed() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                adaptor.append(buffer, withPresentationTime: CMTimeMultiply(step, multiplier: Int32(written)))
                written += 1
            }
            chunkEnd = chunkStart
            progress((end - chunkEnd) / max(duration, 1e-6))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure(message: "Couldn't finish the reversed clip.") }
    }

    private static func reverseAudio(asset: AVAsset, track: AVAssetTrack, start: Double, duration: Double, to url: URL) throws {
        let rate = 48000.0
        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure(message: "Couldn't read the clip's sound.") }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 48000))
        reader.startReading()
        var interleaved: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let base = interleaved.count
            interleaved.append(contentsOf: repeatElement(0, count: length / 4))
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress! + base * 4)
            }
        }
        let frames = interleaved.count / 2
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let l = buffer.floatChannelData?[0], let r = buffer.floatChannelData?[1] else { return }
        for i in 0..<frames {
            let j = frames - 1 - i
            l[i] = interleaved[j * 2]
            r[i] = interleaved[j * 2 + 1]
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
