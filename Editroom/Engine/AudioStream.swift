import AVFoundation
import os

/// Playback sound as one continuous stream. The edit's mixed sound is read from its composition
/// (AVAssetReader, with the edit's audio mix) and queued on a single audio renderer a little ahead of
/// what's being heard, so changes while playing never stop or swap anything: the next sound queued
/// simply comes from the new edit, carrying on sample for sample. When nothing near the playhead
/// changed, it's the same sound and the join can't be heard.
///
/// Times: the renderer runs on its own continuous clock ("render time"). Each queued buffer is stamped
/// with render time = timeline time + an offset, which grows by the loop's length each time a loop
/// goes round, so looping is gapless too.
final class AudioStream: @unchecked Sendable {
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let renderer = AVSampleBufferAudioRenderer()
    private let queue = DispatchQueue(label: "editroom.audio-stream", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    /// How far ahead of what's heard the sound is queued: enough to ride out a busy moment, little
    /// enough that a change is heard soon after it's made.
    private static let ahead = CMTime(seconds: 0.2, preferredTimescale: 48000)
    /// A new reader starts at least this far before where its sound is wanted, and what it reads first is
    /// dropped: a freshly started decoder and resampler take up to about 0.1s to settle, which would click.
    private static let lead = CMTime(seconds: 0.25, preferredTimescale: 48000)

    // Only touched on `queue`.
    private var composition: AVComposition?
    private var mix: AVAudioMix?
    /// The rate sound is read at: the edit's own (most of its sound's), so the reader doesn't resample.
    /// AVFoundation's resampling can come out a few samples early or late from one reader to the next,
    /// which would be heard where one takes over from another; the renderer resamples instead, once, as
    /// the single stream it is.
    private var rate = 48000.0
    private var duration = CMTime.zero
    private var loop: (start: CMTime, end: CMTime)?
    private var feed: Feed?
    /// Where the queued sound ends, in render and timeline time.
    private var queuedEnd: (render: CMTime, media: CMTime)?
    /// Where each stretch of render time starts, for telling which timeline time is being heard.
    private var stretches: [(render: CMTime, offset: CMTime)] = []
    private var playing = false

    private struct Feed {
        let reader: AVAssetReader
        let output: AVAssetReaderAudioMixOutput
        /// render time − timeline time for this stretch.
        let offset: CMTime
        /// Sound before this timeline time is the reader settling, not queued.
        let from: CMTime
        /// Where this stretch ends (the loop's end, or the edit's).
        let until: CMTime
        let rate: Double
    }

    private static func settings(rate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    init() {
        synchronizer.addRenderer(renderer)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    /// The clock the sound plays to; the video players follow it too, so picture and sound never drift.
    var clock: CMClock? { synchronizer.timebase.sourceClock }

    // MARK: Called from the main thread

    /// The edit's sound changed (nil: it has none). Playing, the next sound queued is the new edit's.
    func load(_ composition: AVComposition?, mix: AVAudioMix?, duration: Double, rate: Double) {
        let mix = mix?.copy() as? AVAudioMix
        queue.async {
            self.composition = composition
            self.mix = mix
            self.rate = rate
            self.duration = CompositionBuilder.time(duration)
            if self.playing { self.continueWithNewSound() }
        }
    }

    /// What's looped (nil: nothing). Playing, it takes effect from what's queued next.
    func setLoop(_ span: (start: Double, end: Double)?) {
        queue.async {
            let new = span.map { (start: CompositionBuilder.time($0.start), end: CompositionBuilder.time($0.end)) }
            guard new?.start != self.loop?.start || new?.end != self.loop?.end else { return }
            self.loop = new
            if self.playing { self.continueWithNewSound() }
        }
    }

    /// Starts the sound at timeline time `t`, heard from host time `host` (the picture starts then too).
    func start(at t: Double, host: CMTime) {
        queue.async {
            self.feed?.reader.cancelReading()
            self.renderer.flush()
            let start = CompositionBuilder.time(t)
            // Render time is timeline time at the start.
            self.synchronizer.setRate(1, time: start, atHostTime: host)
            self.playing = true
            self.queuedEnd = (start, start)
            self.stretches = [(start, .zero)]
            self.feed = self.makeFeed(from: start, offset: .zero)
            self.pump()
        }
    }

    func stop() {
        queue.async {
            self.playing = false
            self.synchronizer.rate = 0
            self.feed?.reader.cancelReading()
            self.feed = nil
            self.renderer.flush()
            self.queuedEnd = nil
            self.stretches = []
        }
    }

    /// The timeline time being heard at host time `host` (nil while stopped), for checking against the picture.
    func timelineTime(atHost host: CMTime) -> Double? {
        queue.sync {
            guard playing else { return nil }
            let render = CMSyncConvertTime(host, from: CMClockGetHostTimeClock(), to: synchronizer.timebase)
            guard let stretch = stretches.last(where: { $0.render <= render }) ?? stretches.first else { return nil }
            return (render - stretch.offset).seconds
        }
    }

    // MARK: On the queue

    /// The sound queued from here on is read from the current edit (and loop): what's already queued
    /// plays out, and the new sound follows it exactly.
    private func continueWithNewSound() {
        guard let end = queuedEnd else { return }
        feed?.reader.cancelReading()
        feed = makeFeed(from: end.media, offset: end.render - end.media)
        pump()
    }

    /// A reader of the edit's sound from timeline time `start`, to the loop's end or the edit's.
    private func makeFeed(from start: CMTime, offset: CMTime) -> Feed? {
        guard let composition else { return nil }
        var start = start
        var offset = offset
        if let loop, start >= loop.end - CMTime(seconds: 1 / rate, preferredTimescale: 96000) {
            // At the loop's end: on round to its start.
            offset = offset + (loop.end - loop.start)
            start = loop.start
        }
        let end = loop.map { min($0.end, duration) } ?? duration
        guard end > start else { return nil }
        // Read on a little past a loop's end and cut there here: a reader's last moments before the end
        // of what it's asked for come out slightly differently, which would differ from a join's.
        let readEnd = min(duration, end + Self.lead)
        let tracks = composition.tracks.filter { $0.mediaType == .audio }
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: composition) else { return nil }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: Self.settings(rate: rate))
        output.audioMix = mix
        output.audioTimePitchAlgorithm = .spectral
        // Queued buffers stay with the renderer while the reader reads on, so each gets its own copy.
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        // On a tenth of a second from the timeline's start (a whole number of samples at every usual
        // rate), as every reader of this edit starts, so any that does resample does so alike.
        let readStart = CMTime(value: CMTimeValue(max(0, ((start - Self.lead).seconds * 10).rounded(.down))), timescale: 10)
        reader.timeRange = CMTimeRange(start: readStart, end: readEnd)
        guard reader.startReading() else { return nil }
        if stretches.last?.offset != offset { stretches.append((start + offset, offset)) }
        if stretches.count > 8 { stretches.removeFirst(stretches.count - 8) }
        return Feed(reader: reader, output: output, offset: offset, from: start, until: end, rate: rate)
    }

    /// Keeps the renderer topped up to `ahead` of what's being heard.
    private func pump() {
        guard playing else { return }
        let limit = synchronizer.currentTime() + Self.ahead
        while let feed, renderer.isReadyForMoreMediaData, let end = queuedEnd, end.render < limit {
            guard let read = feed.output.copyNextSampleBuffer().flatMap({ Self.cut($0, at: feed.until, rate: feed.rate) }) else {
                // This stretch is done: round the loop, or that's the end.
                if let loop {
                    self.feed = makeFeed(from: loop.end, offset: feed.offset)
                } else {
                    self.feed = nil
                }
                continue
            }
            // The reader's settling-in sound, before where it was wanted, is dropped.
            guard let buffer = Self.trimmed(read, from: feed.from, rate: feed.rate) else { continue }
            let media = CMSampleBufferGetPresentationTimeStamp(buffer)
            let length = CMSampleBufferGetDuration(buffer)
            guard media.isNumeric, length.isNumeric, let stamped = Self.retimed(buffer, by: feed.offset) else { continue }
            renderer.enqueue(stamped)
            queuedEnd = (media + length + feed.offset, media + length)
        }
    }

    /// The part of a buffer before timeline time `until` (nil if none of it is).
    private static func cut(_ buffer: CMSampleBuffer, at until: CMTime, rate: Double) -> CMSampleBuffer? {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        let count = CMSampleBufferGetNumSamples(buffer)
        let keep = Int(((until - start).seconds * rate).rounded())
        guard keep > 0 else { return nil }
        guard keep < count else { return buffer }
        var out: CMSampleBuffer?
        CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: buffer, sampleRange: CFRange(location: 0, length: keep), sampleBufferOut: &out)
        return out
    }

    /// The part of a buffer from timeline time `from` on (nil if it all comes before).
    private static func trimmed(_ buffer: CMSampleBuffer, from: CMTime, rate: Double) -> CMSampleBuffer? {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        let count = CMSampleBufferGetNumSamples(buffer)
        guard start < from else { return buffer }
        let skip = Int(((from - start).seconds * rate).rounded())
        guard skip < count else { return nil }
        var out: CMSampleBuffer?
        CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: buffer, sampleRange: CFRange(location: skip, length: count - skip),
                                               sampleBufferOut: &out)
        return out
    }

    private static func retimed(_ buffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + offset
            timing[i].decodeTimeStamp = .invalid
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
