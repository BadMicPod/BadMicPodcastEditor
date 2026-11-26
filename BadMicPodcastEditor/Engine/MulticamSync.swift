import AVFoundation
import Foundation

/// Finds how to line up a set of camera angles by matching their sound.
enum MulticamSync {
    /// Sample rate used for the correlation (low enough to be fast, high enough to align).
    static let rate: Double = 8000
    /// How much of each clip to listen to when syncing.
    static let windowSeconds: Double = 60
    /// Largest shift we'll consider, in seconds.
    static let maxLagSeconds: Double = 10

    /// Returns per-angle offsets (seconds) relative to angle 0. Angle 0 is always 0.
    static func offsets(for urls: [URL]) async -> [Double] {
        var signals: [ [Float] ] = []
        for url in urls {
            signals.append(await samples(from: url))
        }
        guard signals.count >= 2 else { return Array(repeating: 0, count: urls.count) }
        let ref = signals[0]
        var result: [Double] = [0]
        for i in 1..<signals.count {
            let lag = bestLag(reference: ref, candidate: signals[i])
            // If angle i lags the reference by `lag` samples, its media time 0 is `lag` samples
            // later, so its sync offset is -lag/rate.
            result.append(-Double(lag) / rate)
        }
        return result
    }

    /// Reads a mono, downsampled chunk of audio from the file.
    private static func samples(from url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { return [] }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var collected: [Float] = []
        let maxSamples = Int(windowSeconds * rate)
        while collected.count < maxSamples {
            guard let sb = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            if let p = dataPointer {
                let count = length / MemoryLayout<Float>.size
                p.withMemoryRebound(to: Float.self, capacity: count) { ptr in
                    let floats = UnsafeBufferPointer(start: ptr, count: count)
                    collected.append(contentsOf: floats)
                }
            }
        }
        reader.cancelReading()
        if collected.count > maxSamples { collected = Array(collected.prefix(maxSamples)) }
        return collected
    }

    /// Cross-correlation: returns the lag (in samples) of `candidate` relative to `reference`
    /// that maximises correlation. Positive lag means candidate is shifted right (later).
    /// Coarse-to-fine: decimate 8x to find the rough lag cheaply, then refine at full rate.
    private static func bestLag(reference: [Float], candidate: [Float]) -> Int {
        guard !reference.isEmpty, !candidate.isEmpty else { return 0 }
        let n = min(reference.count, candidate.count)
        let ref = Array(reference.prefix(n))
        let cand = Array(candidate.prefix(n))
        let maxLag = Int(maxLagSeconds * rate)
        // Coarse pass: every 8th sample.
        let step = 8
        let coarseRef = stride(from: 0, to: n, by: step).map { ref[$0] }
        let coarseCand = stride(from: 0, to: n, by: step).map { cand[$0] }
        let coarseMaxLag = maxLag / step
        var bestCoarse = 0
        var bestScore: Double = -.infinity
        for lag in -coarseMaxLag...coarseMaxLag {
            var dot: Double = 0; var er: Double = 0; var ec: Double = 0
            for i in 0..<coarseRef.count {
                let j = i + lag
                guard j >= 0, j < coarseCand.count else { continue }
                let a = Double(coarseRef[i]); let b = Double(coarseCand[j])
                dot += a*b; er += a*a; ec += b*b
            }
            let denom = sqrt(er*ec)
            let score = denom > 0 ? dot/denom : 0
            if score > bestScore { bestScore = score; bestCoarse = lag }
        }
        // Fine pass around the coarse lag.
        let center = bestCoarse * step
        var bestFine = center
        bestScore = -.infinity
        for lag in (center-8)...(center+8) {
            guard lag >= -maxLag, lag <= maxLag else { continue }
            var dot: Double = 0; var er: Double = 0; var ec: Double = 0
            for i in 0..<n {
                let j = i + lag
                guard j >= 0, j < n else { continue }
                let a = Double(ref[i]); let b = Double(cand[j])
                dot += a*b; er += a*a; ec += b*b
            }
            let denom = sqrt(er*ec)
            let score = denom > 0 ? dot/denom : 0
            if score > bestScore { bestScore = score; bestFine = lag }
        }
        return bestFine
    }
}
