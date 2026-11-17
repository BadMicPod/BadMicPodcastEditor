import AVFoundation

/// Plays a short snippet of the timeline's mixed audio wherever the playhead is dragged or the
/// timeline skimmed, so you can hear where you are. Each snippet is rendered from the same
/// composition and audio mix as playback, so gains, fades and ducking are all heard.
final class AudioScrubber: @unchecked Sendable {
    /// Length of each snippet.
    static let snippet = 0.09
    private static let rate = 48000.0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioScrubber.rate, channels: 2)!
    private let queue = DispatchQueue(label: "cutandplay.audioscrub", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (time: Double, asset: AVAsset, mix: AVAudioMix?)?
    private var working = false
    private var started = false

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Asks for a snippet at a time. If one is still being made, only the latest request is kept,
    /// so it never falls behind the mouse.
    func play(at time: Double, asset: AVAsset, mix: AVAudioMix?) {
        lock.lock()
        pending = (time, asset, mix)
        let start = !working
        working = true
        lock.unlock()
        guard start else { return }
        queue.async { [weak self] in self?.drain() }
    }

    func stop() {
        lock.lock()
        pending = nil
        lock.unlock()
        queue.async { [weak self] in self?.node.stop() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                working = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            guard let buffer = render(job.asset, mix: job.mix, at: job.time) else { continue }
            if !started {
                do { try engine.start() } catch { continue }
                started = true
            }
            node.stop()
            node.scheduleBuffer(buffer, completionHandler: nil)
            node.play()
        }
    }

    func render(_ asset: AVAsset, mix: AVAudioMix?, at time: Double) -> AVAudioPCMBuffer? {
        let tracks = asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = mix
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, time), preferredTimescale: 48000),
                                       duration: CMTime(seconds: Self.snippet, preferredTimescale: 48000))
        guard reader.startReading() else { return nil }

        let capacity = AVAudioFrameCount(Self.rate * Self.snippet) + 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] else { return nil }
        var frames = 0
        while let sample = output.copyNextSampleBuffer(), frames < Int(capacity) {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            var i = 0
            while i + 1 < data.count, frames < Int(capacity) {
                left[frames] = data[i]
                right[frames] = data[i + 1]
                frames += 1
                i += 2
            }
        }
        reader.cancelReading()
        guard frames > 0 else { return nil }
        // Short fades at each end so snippets don't click.
        let ramp = min(frames / 4, Int(Self.rate * 0.006))
        for k in 0..<ramp {
            let g = Float(k) / Float(ramp)
            left[k] *= g; right[k] *= g
            left[frames - 1 - k] *= g; right[frames - 1 - k] *= g
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}
