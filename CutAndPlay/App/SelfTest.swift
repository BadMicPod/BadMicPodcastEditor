import Foundation
import AVFoundation

/// Headless engine check: `Cut and Play --selftest <mediaDir> <outDir>`.
/// Imports every file in mediaDir, builds a small multi-track edit, and exports MP4 + WAV.
@MainActor
enum SelfTest {
    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        let mediaDir = URL(fileURLWithPath: args[i + 1])
        let outDir = URL(fileURLWithPath: args[i + 2])
        Task { @MainActor in
            await run(mediaDir: mediaDir, outDir: outDir)
            exit(0)
        }
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    private static func export(_ project: Project, _ media: MediaStore, _ settings: ExportSettings, to url: URL) async -> Bool {
        let exporter = Exporter()
        exporter.start(project: project, media: media, settings: settings, url: url)
        while exporter.state == .running { try? await Task.sleep(nanoseconds: 50_000_000) }
        if case .done = exporter.state {
            log("EXPORT OK \(url.lastPathComponent)")
            return true
        }
        log("EXPORT FAIL \(url.lastPathComponent): \(exporter.state)")
        return false
    }

    static func run(mediaDir: URL, outDir: URL) async {
        await BaseVideo.load()
        log("base track: \(BaseVideo.track != nil)")
        let media = MediaStore()
        var project = Project()
        let files = ((try? FileManager.default.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            if let a = await media.importFile(f) {
                project.assets.append(a)
                log("IMPORT OK \(f.lastPathComponent) kind=\(a.kind) dur=\(a.duration) \(a.width)x\(a.height) fps=\(a.fps) audio=\(a.hasAudio) converted=\(a.playablePath != nil)")
            } else {
                log("IMPORT FAIL \(f.lastPathComponent)")
            }
        }
        guard let video = project.assets.first(where: { $0.kind == .video && $0.hasAudio }) else {
            log("SELFTEST FAIL no video asset")
            return
        }
        project.width = 1280
        project.height = 720
        project.fps = 30
        let v1 = project.videoTracks[0].id, v2 = project.videoTracks[1].id
        let a1 = project.audioTracks[0].id, a2 = project.audioTracks[1].id

        // 0-2s normal speed, 2-3s at 400% (source 2s..6s), then a solid fading in.
        let l1 = UUID(), l2 = UUID()
        var c1 = Clip(trackID: v1, kind: .video, assetID: video.id, start: 0, duration: 2)
        c1.linkID = l1
        c1.fadeIn = 0.5
        var c1a = Clip(trackID: a1, kind: .audio, assetID: video.id, start: 0, duration: 2)
        c1a.linkID = l1
        c1a.fadeIn = 0.5
        var c2 = Clip(trackID: v1, kind: .video, assetID: video.id, start: 2, duration: 1, sourceStart: 2, speed: 4)
        c2.linkID = l2
        var c2a = Clip(trackID: a1, kind: .audio, assetID: video.id, start: 2, duration: 1, sourceStart: 2, speed: 4)
        c2a.linkID = l2
        var solid = Clip(trackID: v1, kind: .solid, start: 3.5, duration: 1)
        solid.color = RGBA(r: 0.9, g: 0.2, b: 0.2, a: 1)
        solid.fadeIn = 0.5
        var text = Clip(trackID: v2, kind: .text, start: 0.5, duration: 2)
        text.text.string = "Cut and Play"
        text.fadeIn = 0.5
        text.fadeOut = 0.5
        project.clips = [c1, c1a, c2, c2a, solid, text]

        if let small = project.assets.first(where: { $0.kind == .video && $0.id != video.id }) {
            // Picture-in-track test: a second source on V2 over the sped-up section.
            project.clips.append(Clip(trackID: v2, kind: .video, assetID: small.id, start: 2.5, duration: min(1, small.duration)))
        }
        if let tone = project.assets.first(where: { $0.kind == .audio }) {
            var t = Clip(trackID: a2, kind: .audio, assetID: tone.id, start: 1, duration: min(3, tone.duration))
            t.gainDB = -6
            t.fadeOut = 1
            project.clips.append(t)
        }
        project.sanitize()
        log("project duration \(project.duration)")
        if let data = try? JSONEncoder().encode(SavedDocument(project: project)) {
            try? data.write(to: outDir.appendingPathComponent("selftest.cutplay"))
        }

        var ok = true
        var s = ExportSettings()
        ok = await export(project, media, s, to: outDir.appendingPathComponent("edit_h264.mp4")) && ok
        s.codec = .hevc
        s.quality = .web
        s.height = 2160
        ok = await export(project, media, s, to: outDir.appendingPathComponent("edit_hevc_4k_web.mp4")) && ok
        s = ExportSettings()
        s.includeAudio = false
        s.height = 360
        ok = await export(project, media, s, to: outDir.appendingPathComponent("edit_noaudio.mp4")) && ok
        s = ExportSettings()
        s.format = .wav
        ok = await export(project, media, s, to: outDir.appendingPathComponent("edit.wav")) && ok

        // Gain check: a lone tone at +6 dB and at 0 dB.
        if let tone = project.assets.first(where: { $0.kind == .audio }) {
            for (name, db) in [("tone_0db.wav", 0.0), ("tone_plus6.wav", 6.0), ("tone_minus12.wav", -12.0)] {
                var p = Project()
                p.assets = project.assets
                var c = Clip(trackID: p.audioTracks[0].id, kind: .audio, assetID: tone.id, start: 0, duration: min(2, tone.duration))
                c.gainDB = db
                p.clips = [c]
                ok = await export(p, media, s, to: outDir.appendingPathComponent(name)) && ok
            }
        }
        log(ok ? "SELFTEST OK" : "SELFTEST FAIL")
    }
}
