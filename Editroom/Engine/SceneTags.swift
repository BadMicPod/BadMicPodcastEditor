import AVFoundation
import Foundation
import ImageIO
import Vision

/// What a clip or photo shows ("pool", "beach", "dog", "sunset"), seen on this Mac by Apple's Vision,
/// from a frame every couple of seconds. Made once per file in the background and kept on disk, for Media
/// search and Magic.
struct SceneTags: Codable, Equatable {
    struct Tag: Codable, Equatable {
        var name: String
        /// How sure Vision is, at the frame it was surest (0 to 1).
        var confidence: Double
        /// Times in the file where it shows.
        var times: [Double]
    }

    var tags: [Tag]

    /// The surest few, for a short summary.
    func top(_ n: Int) -> [String] { tags.sorted { $0.confidence > $1.confidence }.prefix(n).map(\.name) }

    /// Whether one of its tags is this word, or starts with it while it's being typed ("po" for "pool").
    func shows(_ word: String, typing: Bool = false) -> Bool {
        let w = Self.singular(word.lowercased())
        guard w.count >= 2 else { return false }
        return tags.contains { tag in
            tag.name.split(separator: " ").contains { part in
                let p = String(part)
                return p == w || Self.singular(p) == w || (typing && p.hasPrefix(w))
            }
        }
    }

    static func singular(_ w: String) -> String {
        w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") ? String(w.dropLast()) : w
    }
}

@MainActor
final class SceneTagStore: ObservableObject {
    static let shared = SceneTagStore()

    @Published private(set) var version = 0
    private var made: [String: SceneTags] = [:]
    private var queue: [(URL, Bool, Double)] = []
    private var working: URL?

    func tags(for url: URL) -> SceneTags? { made[url.path] ?? load(url) }

    /// Queues a file: a video (`isVideo`, with its length) or a photo.
    func make(_ url: URL, isVideo: Bool, duration: Double) {
        guard made[url.path] == nil, working != url, !queue.contains(where: { $0.0 == url }) else { return }
        if load(url) != nil { return }
        queue.append((url, isVideo, duration))
        next()
    }

    private func next() {
        guard working == nil, !queue.isEmpty else { return }
        let (url, isVideo, duration) = queue.removeFirst()
        working = url
        Task.detached(priority: .utility) {
            let result = isVideo ? await Self.seeVideo(url, duration: duration) : Self.seePhoto(url)
            await MainActor.run {
                let store = SceneTagStore.shared
                store.working = nil
                if let result {
                    store.made[url.path] = result
                    store.save(result, for: url)
                    store.version += 1
                }
                store.next()
            }
        }
    }

    // MARK: On disk

    nonisolated static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func file(for url: URL) -> URL { Self.folder.appendingPathComponent(ReverseAudio.cacheName(for: url) + ".json") }

    private func load(_ url: URL) -> SceneTags? {
        guard let data = try? Data(contentsOf: file(for: url)), let t = try? JSONDecoder().decode(SceneTags.self, from: data) else { return nil }
        made[url.path] = t
        return t
    }

    private func save(_ t: SceneTags, for url: URL) {
        if let data = try? JSONEncoder().encode(t) { try? data.write(to: file(for: url), options: .atomic) }
    }

    // MARK: Looking

    /// Kept: tags Vision is fairly sure of somewhere in the clip.
    nonisolated static let sure = 0.45

    nonisolated static func seeVideo(_ url: URL, duration: Double) async -> SceneTags? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        let n = min(20, max(3, Int(duration / 2)))
        var seen: [(Double, [(String, Double)])] = []
        for i in 0..<n {
            let t = duration * (Double(i) + 0.5) / Double(n)
            guard let image = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            seen.append((t, classify(image)))
        }
        guard !seen.isEmpty else { return nil }
        return gather(seen)
    }

    nonisolated static func seePhoto(_ url: URL) -> SceneTags? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
              ] as CFDictionary) else { return nil }
        return gather([(0, classify(image))])
    }

    nonisolated private static func classify(_ image: CGImage) -> [(String, Double)] {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { Double($0.confidence) >= 0.2 }
            .map { ($0.identifier.replacingOccurrences(of: "_", with: " "), Double($0.confidence)) }
    }

    nonisolated private static func gather(_ seen: [(Double, [(String, Double)])]) -> SceneTags {
        var best: [String: (Double, [Double])] = [:]
        for (t, labels) in seen {
            for (name, c) in labels {
                var e = best[name] ?? (0, [])
                e.0 = max(e.0, c)
                if c >= sure { e.1.append((t * 100).rounded() / 100) }
                best[name] = e
            }
        }
        let tags = best.filter { $0.value.0 >= sure }
            .map { SceneTags.Tag(name: $0.key, confidence: ($0.value.0 * 100).rounded() / 100, times: $0.value.1) }
            .sorted { $0.confidence > $1.confidence }
        return SceneTags(tags: tags)
    }
}
