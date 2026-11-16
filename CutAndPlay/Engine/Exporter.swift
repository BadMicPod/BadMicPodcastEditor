import AVFoundation
import AppKit

struct ExportSettings: Equatable {
    enum Format: String, CaseIterable { case mp4 = "Video", wav = "Audio" }
    enum Quality: String, CaseIterable { case high = "High", web = "Web" }
    enum Codec: String, CaseIterable { case h264 = "H.264", hevc = "HEVC" }

    var format = Format.mp4
    /// Output height; nil keeps the sequence size.
    var height: Int?
    var codec = Codec.h264
    var quality = Quality.high
    var includeAudio = true

    func renderSize(for project: Project) -> CGSize {
        let h = Double(height ?? project.height)
        let w = h * Double(project.width) / Double(max(1, project.height))
        return CGSize(width: max(2, (w / 2).rounded() * 2), height: max(2, (h / 2).rounded() * 2))
    }

    func videoBitrate(size: CGSize, fps: Double) -> Int {
        var bpp = quality == .high ? 0.2 : 0.085
        if codec == .hevc { bpp *= 0.62 }
        return Int(Double(size.width * size.height) * min(fps, 60) * bpp)
    }

    var fileExtension: String { format == .mp4 ? "mp4" : "wav" }
}

@MainActor
final class Exporter: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case done(URL)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var progress = 0.0
    private var job: ExportJob?

    func reset() {
        if state != .running { state = .idle }
    }

    func cancel() {
        job?.cancelled = true
    }

    func start(project: Project, media: MediaStore, settings: ExportSettings, url: URL) {
        guard state != .running else { return }
        progress = 0
        let wav = settings.format == .wav
        let size = settings.renderSize(for: project)
        guard let built = CompositionBuilder.build(project: project, media: media, renderSize: size,
                                                   includeVideo: !wav, includeAudio: wav || settings.includeAudio) else {
            state = .failed("The timeline is empty.")
            return
        }
        if wav && !built.hasAudio {
            state = .failed("There's no audio on the timeline.")
            return
        }
        do {
            let job = try ExportJob(built: built, settings: settings, size: size, fps: project.fps, url: url)
            self.job = job
            state = .running
            job.run(progress: { [weak self] p in
                Task { @MainActor in
                    guard let self, self.state == .running else { return }
                    self.progress = max(self.progress, p)
                }
            }, completion: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.job = nil
                    if let error {
                        self.state = (error as? ExportJob.Cancelled) != nil ? .idle : .failed(error.localizedDescription)
                    } else {
                        self.progress = 1
                        self.state = .done(url)
                    }
                }
            })
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Reads the composition through the custom compositor and audio mix, and encodes it.
final class ExportJob {
    struct Cancelled: Error {}

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
    private let duration: Double
    private let url: URL
    var cancelled = false

    init(built: BuiltTimeline, settings: ExportSettings, size: CGSize, fps: Double, url: URL) throws {
        self.url = url
        duration = built.duration
        try? FileManager.default.removeItem(at: url)
        let wav = settings.format == .wav
        reader = try AVAssetReader(asset: built.composition)
        writer = try AVAssetWriter(outputURL: url, fileType: wav ? .wav : .mp4)
        writer.shouldOptimizeForNetworkUse = true

        if !wav {
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: built.composition.tracks(withMediaType: .video),
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = built.videoComposition
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw NSError(domain: "CutAndPlay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't set up video rendering."]) }
            reader.add(output)

            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: settings.videoBitrate(size: size, fps: fps),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int((fps * 2).rounded()),
            ]
            if settings.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: settings.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: compression,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw NSError(domain: "CutAndPlay", code: 3, userInfo: [NSLocalizedDescriptionKey: "This resolution isn't supported by the encoder."]) }
            writer.add(input)
            pairs.append((output, input))
        }

        if built.hasAudio {
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: wav ? 24 : 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderAudioMixOutput(audioTracks: built.composition.tracks(withMediaType: .audio), audioSettings: pcm)
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                var stereo = AudioChannelLayout()
                stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                let layout = Data(bytes: &stereo, count: MemoryLayout<AudioChannelLayout>.size)
                var settingsOut: [String: Any] = wav ? pcm : [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: settings.quality == .high ? 256_000 : 160_000,
                ]
                settingsOut[AVChannelLayoutKey] = layout
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settingsOut)
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    pairs.append((output, input))
                }
            }
        }
        guard !pairs.isEmpty else { throw NSError(domain: "CutAndPlay", code: 4, userInfo: [NSLocalizedDescriptionKey: "Nothing to export."]) }
    }

    func run(progress: @escaping (Double) -> Void, completion: @escaping (Error?) -> Void) {
        guard writer.startWriting() else { return completion(writer.error ?? Cancelled()) }
        guard reader.startReading() else {
            writer.cancelWriting()
            return completion(reader.error ?? Cancelled())
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let total = max(duration, 0.001)
        for (index, pair) in pairs.enumerated() {
            let (output, input) = pair
            let queue = DispatchQueue(label: "cutandplay.export.\(index)")
            var lastReported = -1.0
            group.enter()
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                while input.isReadyForMoreMediaData {
                    guard let self, !self.cancelled, let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if index == 0 {
                        let p = CMSampleBufferGetPresentationTimeStamp(sample).seconds / total
                        if p - lastReported >= 0.005 {
                            lastReported = p
                            progress(min(1, p))
                        }
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) { [self] in
            if cancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                completion(Cancelled())
            } else if reader.status == .failed {
                writer.cancelWriting()
                completion(reader.error ?? Cancelled())
            } else if writer.status == .failed {
                completion(writer.error ?? Cancelled())
            } else {
                writer.finishWriting { [self] in
                    completion(writer.status == .completed ? nil : (writer.error ?? Cancelled()))
                }
            }
        }
    }
}
