import AppKit
import Foundation
import AVFoundation

/// Headless engine check: `Editroom --selftest <mediaDir> <outDir>`.
/// Imports every file in mediaDir, builds a small multi-track edit, and exports MP4 + WAV.
@MainActor
enum SelfTest {
    nonisolated static func runIfRequested() {
        let args = CommandLine.arguments
        // `--bench <dir>`: how fast the preview pipeline makes frames from the 4K clips in a folder.
        if let i = args.firstIndex(of: "--bench"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                await bench(dir)
                exit(0)
            }
            return
        }
        // `--reverse-bench <file>...`: how long reversing each whole file takes.
        if let i = args.firstIndex(of: "--reverse-bench") {
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                let media = MediaStore()
                for f in files {
                    guard let a = await media.importFile(f) else { log("RBENCH can't open \(f.lastPathComponent)"); continue }
                    // Sound: made once per file (the cached copy is removed first, to time it fresh).
                    if a.hasAudio || a.kind == .audio {
                        try? FileManager.default.removeItem(at: ReverseAudio.cacheURL(for: a.url))
                        let t0 = Date()
                        await media.prepareReversedAudio(a.id)?.value
                        log(String(format: "RBENCH %@ %.1fs long: sound reversed in %.2fs (ready=%@)", f.lastPathComponent, a.duration,
                                   Date().timeIntervalSince(t0), media.runtimes[a.id]?.reversedAudio != nil ? "yes" : "no"))
                    }
                    // Picture: frames played backwards in order, as fast as they come.
                    if let frames = media.runtimes[a.id]?.reverseFrames {
                        for limit in [1920, 3840] {
                            let fps = max(24, a.fps)
                            let n = Int(min(a.duration, 6) * fps)
                            let t0 = Date()
                            var got = 0
                            for i in 0..<n where frames.frame(before: a.duration - Double(i) / fps, limit: limit) != nil { got += 1 }
                            let dt = Date().timeIntervalSince(t0)
                            log(String(format: "RBENCH %@ backwards at %d px: %d/%d frames, %.0f fps (needs %.0f)", f.lastPathComponent, limit, got, n, Double(n) / dt, a.fps))
                        }
                    }
                }
                exit(0)
            }
            return
        }
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        let mediaDir = URL(fileURLWithPath: args[i + 1])
        let outDir = URL(fileURLWithPath: args[i + 2])
        Task { @MainActor in
            await run(mediaDir: mediaDir, outDir: outDir)
            exit(0)
        }
    }

    @MainActor
    static func bench(_ dir: URL) async {
        await BaseVideo.load()
        let media = MediaStore()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var assets: [MediaAsset] = []
        for f in files { if let a = await media.importFile(f) { assets.append(a) } }
        guard let a60 = assets.first(where: { $0.fps > 50 }), let a30 = assets.first(where: { $0.fps < 50 }) else { log("BENCH needs a 4K60 and a 4K30 clip"); return }

        func project(heavy: Bool) -> Project {
            var p = Project()
            p.width = 3840; p.height = 2160; p.fps = 60
            p.assets = assets
            let v1 = p.videoTracks[0].id, v2 = p.videoTracks[1].id
            var base = Clip(trackID: v1, kind: .video, assetID: a60.id, start: 0, duration: 10)
            if heavy {
                var g = ColorGrade()
                g.look = "Teal and orange"
                g.exposure = 0.3
                g.midtones = WheelPoint(x: 0.4, y: -0.2)
                base.grade = g
                var pip = Clip(trackID: v2, kind: .video, assetID: a30.id, start: 0, duration: 10)
                pip.transform = ClipTransform(scale: 0.45, x: 0.22, y: -0.2)
                pip.fadeIn = 1
                let v3 = p.addTrack(.video)
                var text = Clip(trackID: v3, kind: .text, start: 0, duration: 10)
                text.text.string = "Benchmark"
                p.clips = [base, pip, text]
            } else {
                p.clips = [base]
            }
            return p
        }

        for (name, heavy) in [("single 4K60 clip", false), ("4K60 graded + 4K30 picture-in-picture + text", true)] {
            let p = project(heavy: heavy)
            let size = CompositionBuilder.previewSize(for: p)
            guard let built = CompositionBuilder.build(project: p, media: media, renderSize: size, includeAudio: false),
                  let reader = try? AVAssetReader(asset: built.composition) else { continue }
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video),
                                                             videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.videoComposition = built.videoComposition
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
            let t0 = CACurrentMediaTime()
            reader.startReading()
            var frames = 0
            while output.copyNextSampleBuffer() != nil { frames += 1 }
            let secs = CACurrentMediaTime() - t0
            log(String(format: "BENCH %@: %d frames at %dx%d in %.2fs = %.0f fps (playback needs 60)", name, frames, Int(size.width), Int(size.height), secs, Double(frames) / secs))
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
        // Half size, in the top-right quarter of the frame.
        solid.transform = ClipTransform(scale: 0.5, x: 0.25, y: -0.25)
        var text = Clip(trackID: v2, kind: .text, start: 0.5, duration: 2)
        text.text.string = "Editroom"
        text.fadeIn = 0.5
        text.fadeOut = 0.5
        text.fadeOutCurve = .smooth
        // Grade the sped-up section: mono look plus a strong warm push in the highlights.
        var grade = ColorGrade()
        grade.look = "Mono"
        grade.highlights = WheelPoint(x: 1, y: 0)
        c2.grade = grade
        // Dissolve from the normal-speed section into the graded, sped-up one.
        c2.transitionIn = Transition(kind: .dissolve, duration: 0.5)
        c1.fadeInCurve = .easeIn
        c1a.fadeInCurve = .easeIn
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
            try? data.write(to: outDir.appendingPathComponent("selftest.room"))
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
        // Speed change on several clips: they stay butted together, and untouched clips are pushed, never overlapped.
        do {
            var p = Project()
            p.assets = project.assets
            let t = p.videoTracks[0].id
            let a = Clip(trackID: t, kind: .video, assetID: video.id, start: 0, duration: 2)
            let b = Clip(trackID: t, kind: .video, assetID: video.id, start: 2, duration: 2, sourceStart: 2)
            let c = Clip(trackID: t, kind: .solid, start: 4, duration: 1)
            p.clips = [a, b, c]
            var fast = p
            fast.setSpeed(ids: [a.id, b.id], speed: 2)
            var slow = p
            slow.setSpeed(ids: [a.id, b.id], speed: 0.5)
            let f = fast.clips.map { [$0.start, $0.end] }, sl = slow.clips.map { [$0.start, $0.end] }
            let pass = f == [[0, 1], [1, 2], [4, 5]] && sl == [[0, 4], [4, 8], [8, 9]]
            log("SPEED GROUP \(pass ? "OK" : "FAIL") fast=\(f) slow=\(sl)")
            ok = ok && pass
        }
        // Speed ramps: 100% → 400% → 100% over 4s of footage. Timing round-trips, the footage stays the
        // same, a split keeps both halves on the same curve, reversing mirrors it, and it exports.
        do {
            var p = Project()
            p.assets = project.assets
            let t = p.videoTracks[0].id, at = p.audioTracks[0].id
            let link = UUID()
            var v = Clip(trackID: t, kind: .video, assetID: video.id, start: 0, duration: 4, sourceStart: 0.5)
            v.linkID = link
            var a = v
            a.id = UUID()
            a.trackID = at
            a.kind = .audio
            let after = Clip(trackID: t, kind: .solid, start: 4, duration: 1)
            p.clips = [v, a, after]
            p.setRamp(ids: [v.id, a.id], speed: 4, points: (0, 0.25, 0.75, 1), start: 1, end: 1)
            let rv = p.clip(v.id)!, ra = p.clip(a.id)!
            let footage = abs(rv.sourceLength - 4) < 0.02
            // Pure 400% would be 1s, pure 100% 4s: a ramp at both ends lands in between.
            let shorter = rv.duration > 1.2 && rv.duration < 3
            let together = abs(ra.duration - rv.duration) < 1e-6 && p.clip(after.id)!.start >= rv.end - 1e-6
            var trips = true
            for x in stride(from: 0.0, through: 4, by: 0.37) {
                let s = rv.sourceStart + x
                let back = rv.sourceTime(at: rv.start + rv.timelineSpan(from: rv.sourceStart, to: s))
                if abs(back - s) > 1e-4 { trips = false }
            }
            let ends = abs(rv.speed(atSource: rv.sourceStart) - 1) < 1e-6 && abs(rv.speed(atSource: rv.sourceStart + 2) - 4) < 1e-6
            var q = p
            let mid = rv.start + rv.duration * 0.3
            _ = q.split(ids: [rv.id], at: mid)
            let halves = q.clips.filter { $0.trackID == t && $0.kind == .video }.sorted { $0.start < $1.start }
            let split = halves.count == 2 && abs(halves[0].sourceLength + halves[1].sourceLength - rv.sourceLength) < 1e-3
                && abs(halves[1].sourceStart - rv.sourceTime(at: mid)) < 1e-4
                && abs(halves[1].speed(atSource: halves[1].sourceStart) - rv.speed(atSource: halves[1].sourceStart)) < 1e-9
            let length = video.duration
            let m = rv.ramp!.mirrored(length: length)
            let mirrored = abs(m.speed(at: length - (rv.sourceStart + 0.3), mid: 4) - rv.speed(atSource: rv.sourceStart + 0.3)) < 1e-9
            var back = p
            back.setRamp(ids: [v.id, a.id], speed: 4, points: (0, 0, 1, 1), start: 1, end: 1)
            // A slow-motion moment in the middle: 100% to 30% of the way, easing to 25% by 40%, held to
            // 60%, back to 100% by 70%, then 100% to the end.
            var moment = p
            moment.setRamp(ids: [v.id, a.id], speed: 0.25, points: (0.3, 0.4, 0.6, 0.7), start: 1, end: 1)
            let mc = moment.clip(v.id)!
            let L = mc.sourceLength, s0 = mc.sourceStart
            let middle = abs(mc.speed(atSource: s0 + 0.1 * L) - 1) < 1e-6 && abs(mc.speed(atSource: s0 + 0.5 * L) - 0.25) < 1e-6
                && abs(mc.speed(atSource: s0 + 0.9 * L) - 1) < 1e-6 && abs(L - rv.sourceLength) < 0.02
                && abs(mc.duration - L * (0.6 + 0.2 / 0.25 + 0.2 * 2.2)) < 0.6
            let flat = back.clip(v.id)!.ramp == nil && abs(back.clip(v.id)!.duration - 1) < 0.04
            p.sanitize()
            let exported = await export(p, media, ExportSettings(), to: outDir.appendingPathComponent("ramp.mp4"))
            let file = AVURLAsset(url: outDir.appendingPathComponent("ramp.mp4"))
            let seconds = (try? await file.load(.duration).seconds) ?? 0
            let lasts = abs(seconds - p.duration) < 0.1
            let pass = footage && shorter && together && trips && ends && split && mirrored && flat && middle && exported && lasts
            if !pass {
                log("RAMP DEBUG v=\(rv.start)+\(rv.duration) a=\(ra.start)+\(ra.duration) after=\(p.clip(after.id)!.start) halves=\(halves.map { [$0.start, $0.duration, $0.sourceStart, $0.sourceLength] }) mid=\(mid) src(mid)=\(rv.sourceTime(at: mid))")
            }
            log("RAMP \(pass ? "OK" : "FAIL") footage=\(footage) length=\(String(format: "%.2f", rv.duration)) together=\(together) trips=\(trips) ends=\(ends) split=\(split) mirrored=\(mirrored) flat=\(flat) middle=\(middle) (\(String(format: "%.2f", mc.duration))s) export=\(exported) lasts=\(lasts) (\(String(format: "%.2f", seconds)) of \(String(format: "%.2f", p.duration)))")
            ok = ok && pass
        }
        // Zoom/scroll limits: whatever is asked for, the state must stay inside the bars and be stable.
        do {
            let m = EditorModel()
            m.load(project, url: nil)
            m.view.viewWidth = 1500
            m.view.viewHeight = 360
            m.clampView()
            var pass = true
            func check(_ label: String) {
                let v = m.view
                let extent = CGFloat(m.extent)
                let span = v.viewWidth / v.pps
                let before = (v.pps, v.scrollX, v.scrollY, v.rowHeight)
                m.clampView()
                let stable = before == (v.pps, v.scrollX, v.scrollY, v.rowHeight)
                let good = stable && span <= extent + 0.001 && v.scrollX >= 0 && v.scrollX / v.pps + span <= extent + 0.001
                    && v.scrollY >= m.minScrollY - 0.001 && v.scrollY <= m.maxScrollY + 0.001 && m.minScrollY <= m.maxScrollY + 0.001 && m.rowWindow > 0 && m.rowWindow <= 1
                    && TimelineViewState.rowRange.contains(v.rowHeight)
                if !good { log("VIEW FAIL \(label) pps=\(v.pps) x=\(v.scrollX) y=\(v.scrollY) row=\(v.rowHeight)") }
                pass = pass && good
            }
            check("initial")
            // Bar grips: the dragged edge tracks the mouse, the other mirrors it, and an edge at the end stays put.
            func grip(_ part: Int, _ a: CGFloat, _ b: CGFloat, _ move: CGFloat, _ wantA: CGFloat, _ wantB: CGFloat, _ label: String) {
                let e = gripDrag(part: part, start: a, end: b, move: move, bar: 400, minLength: 20, maxLength: 400)
                let good = abs(e.start - wantA) < 0.01 && abs(e.end - wantB) < 0.01
                if !good { log("GRIP FAIL \(label): \(e.start) \(e.end)") }
                pass = pass && good
            }
            grip(2, 100, 200, 30, 70, 230, "end grip, both free")
            grip(0, 100, 200, -30, 70, 230, "start grip, both free")
            grip(2, 0, 200, 30, 0, 230, "end grip, start at end of bar")
            grip(0, 150, 400, -30, 120, 400, "start grip, end at end of bar")
            grip(0, 0, 200, -30, 0, 200, "start grip already at end, pulled out")
            grip(2, 150, 400, 30, 150, 400, "end grip already at end, pulled out")
            grip(0, 0, 200, 30, 30, 170, "start grip at end, pushed in")
            grip(2, 100, 200, 500, 0, 400, "end grip past the bar")
            grip(2, 100, 200, -500, 140, 160, "end grip squeezed to minimum")
            // Playhead at the start edge: only the dragged end moves.
            let held = gripDrag(part: 2, start: 0, end: 200, move: -60, bar: 400, minLength: 20, maxLength: 400, mirror: 0)
            // Playhead a quarter of the way in: the far edge moves a third as much, so the playhead holds its place.
            let quarter = gripDrag(part: 2, start: 100, end: 200, move: -30, bar: 400, minLength: 20, maxLength: 400, mirror: 1.0 / 3)
            let anchored = held.start == 0 && abs(held.end - 140) < 0.01 && abs(quarter.start - 110) < 0.01 && abs(quarter.end - 170) < 0.01
                && abs((125 - quarter.start) / (quarter.end - quarter.start) - 0.25) < 0.001
            if !anchored { log("GRIP FAIL playhead anchor") }
            pass = pass && anchored
            m.setView(pps: 0.0001); check("zoom out past limit")
            let fullyOut = m.view.pps
            m.setView(pps: 0.0001); pass = pass && m.view.pps == fullyOut
            m.setView(pps: 1e9, scrollX: 1e9); check("zoom in past limit")
            m.setView(scrollX: -500, scrollY: -500); check("scroll before start")
            m.setView(scrollY: 1e9, rowHeight: 9999); check("tallest rows, scrolled to end")
            m.setView(rowHeight: 1); check("shortest rows")
            // At the smallest rows everything fits, the thumb fills the bar and the tracks sit centred.
            pass = pass && m.rowWindow == 1 && abs(m.view.scrollY - m.centeredScrollY) < 0.001
            // With more video than audio tracks, the centre is still the video/audio gap.
            m.addTrack(.video)
            m.addTrack(.video)
            m.addTrack(.video)
            // A centred thumb always means centred tracks, at any row height.
            for row in [30.0, 62.0, 110.0] {
                m.setView(rowHeight: row)
                m.setView(scrollY: (m.minScrollY + m.maxScrollY) / 2)
                let gapOnScreen = m.rowsAbove - m.view.scrollY
                let centred = abs(m.view.scrollY - m.centeredScrollY) < 0.001 && abs(gapOnScreen - m.rowsVisible / 2) < 0.001
                if !centred { log("VIEW FAIL centre at row \(row)") }
                pass = pass && centred
                check("centred at row \(row)")
            }
            m.seek(to: 2)
            for f in [0.5, 3.0, 0.2, 7.0, 0.01, 40.0] {
                let px = CGFloat(m.playhead) * m.view.pps - m.view.scrollX
                m.zoom(by: f)
                let after = CGFloat(m.playhead) * m.view.pps - m.view.scrollX
                // The playhead holds its place unless a scroll limit is in the way.
                let pinned = abs(px - after) < 0.5 || m.view.scrollX == 0 || abs(m.view.scrollX - m.maxScrollX) < 0.5 || px < 0 || px > m.view.viewWidth
                if !pinned { log("VIEW FAIL playhead moved \(px) -> \(after)") }
                pass = pass && pinned
                check("zoom x\(f)")
            }
            log("VIEW LIMITS \(pass ? "OK" : "FAIL")")
            ok = ok && pass
        }
        // Missing media: a project folder moved as a whole finds its files by relative path, and
        // relinking one file finds the others beside it.
        // It needs two particular files in the media folder; without them it's skipped, not crashed.
        let relinkFiles = ["a_main.mp4", "b_tone.wav"]
        if !relinkFiles.allSatisfy({ FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent($0).path) }) {
            log("RELINK SKIP needs \(relinkFiles.joined(separator: " and ")) in the media folder")
        } else {
            let fm = FileManager.default
            let work = outDir.appendingPathComponent("relink")
            try? fm.removeItem(at: work)
            let first = work.appendingPathComponent("first"), footage = first.appendingPathComponent("footage")
            try? fm.createDirectory(at: footage, withIntermediateDirectories: true)
            var p = Project()
            for name in ["a_main.mp4", "b_tone.wav"] {
                let copy = footage.appendingPathComponent(name)
                try? fm.copyItem(at: mediaDir.appendingPathComponent(name), to: copy)
                if let a = await media.importFile(copy) { p.assets.append(a) }
            }
            if p.assets.count != relinkFiles.count {
                log("RELINK FAIL imported \(p.assets.count) of \(relinkFiles.count) files")
                ok = false
            } else {
            p.stampRelativePaths(projectDir: first)
            let second = work.appendingPathComponent("second")
            try? fm.moveItem(at: first, to: second)
            var moved = p
            let found = moved.resolveMovedMedia(projectDir: second)
            let relative = p.assets.count == 2 && found == 2 && moved.assets.allSatisfy { fm.fileExists(atPath: $0.path) }
                && p.assets[0].relativePath == "footage/a_main.mp4"

            // Now scatter the files somewhere the relative paths don't reach, and relink just one.
            let elsewhere = work.appendingPathComponent("elsewhere")
            try? fm.moveItem(at: second.appendingPathComponent("footage"), to: elsewhere)
            let m = EditorModel()
            m.load(p, url: nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let missingBefore = m.missingAssets.count
            let linked = await m.relink(p.assets[0].id, to: elsewhere.appendingPathComponent("a_main.mp4"))
            let wrongKind = await m.relink(p.assets[0].id, to: elsewhere.appendingPathComponent("b_tone.wav"))
            let swept = linked && !wrongKind && missingBefore == 2 && m.missingAssets.isEmpty
                && m.project.assets.map(\.id) == p.assets.map(\.id)
                && m.project.assets.allSatisfy { !m.media.isOffline($0) }
            log("RELINK \(relative && swept ? "OK" : "FAIL") relative=\(relative) swept=\(swept) missingBefore=\(missingBefore)")
            ok = ok && relative && swept
            }
        }
        // Sticky edges: three butted clips; shortening the first pulls the other two back, and a
        // linked partner follows its clip.
        do {
            var p = Project()
            let v = p.videoTracks[0].id, a = p.audioTracks[0].id
            let link = UUID()
            let c1 = Clip(trackID: v, kind: .solid, start: 0, duration: 4)
            let c2 = Clip(trackID: v, kind: .solid, start: 4, duration: 2, linkID: link)
            let c3 = Clip(trackID: v, kind: .solid, start: 6, duration: 1)
            let c2a = Clip(trackID: a, kind: .solid, start: 4, duration: 2, linkID: link)
            let far = Clip(trackID: v, kind: .solid, start: 9, duration: 1)
            p.clips = [c1, c2, c3, c2a, far]
            var short = c1
            short.trimTail(to: 3)
            let carried = p.carried(by: [c1.id: short])
            let pulled = carried[c2.id]?.start == 3 && carried[c3.id]?.start == 5 && carried[c2a.id]?.start == 3 && carried[far.id] == nil
            // Growing it by 3 pushes the chain into the far clip, which joins in.
            var long = c1
            long.trimTail(to: 7)
            let pushed = p.carried(by: [c1.id: long])
            let grew = pushed[c3.id]?.start == 9 && pushed[far.id]?.start == 10 && p.fits(pushed.merging([c1.id: long]) { a, _ in a })
            // Doubling the speed of a 4s video clip halves it, and the touching clip follows it back.
            var q = Project()
            let qv = q.videoTracks[0].id
            let fastClip = Clip(trackID: qv, kind: .video, start: 0, duration: 4)
            let next = Clip(trackID: qv, kind: .solid, start: 4, duration: 2)
            q.clips = [fastClip, next]
            var plain = q
            plain.setSpeed(ids: [fastClip.id], speed: 2)
            q.setSpeed(ids: [fastClip.id], speed: 2, sticky: true)
            let sped = q.clip(fastClip.id)?.duration == 2 && q.clip(next.id)?.start == 2 && plain.clip(next.id)?.start == 4
            log("STICKY \(pulled && grew && sped ? "OK" : "FAIL") pulled=\(pulled) grew=\(grew) speed=\(sped)")
            ok = ok && pulled && grew && sped
        }
        // Tracks: old files without solo/lock still open; solo silences the others; locked clips are left out.
        do {
            let old = #"{"id":"6F1D8C64-1B2E-4C38-9A6E-0B9C1F6A1B2C","kind":"audio","hidden":false,"muted":false,"gainDB":0}"#
            let decoded = (try? JSONDecoder().decode(Track.self, from: Data(old.utf8))).map { !$0.solo && !$0.locked } ?? false
            var p = Project()
            p.audioTracks[1].solo = true
            let solo = !p.isAudible(p.audioTracks[0]) && p.isAudible(p.audioTracks[1])
            p.videoTracks[0].locked = true
            let a = Clip(trackID: p.videoTracks[0].id, kind: .solid, start: 0, duration: 1)
            let b = Clip(trackID: p.videoTracks[1].id, kind: .solid, start: 0, duration: 1)
            p.clips = [a, b]
            let lock = p.unlocked([a.id, b.id]) == [b.id]
            log("TRACKS \(decoded && solo && lock ? "OK" : "FAIL") decode=\(decoded) solo=\(solo) lock=\(lock)")
            ok = ok && decoded && solo && lock
        }
        // Magic history: kept in the project file, newest first and each once, and undo leaves it alone.
        do {
            let m = EditorModel()
            m.addMagicPrompt("make a quick cut", tab: .local)
            m.mutate { $0.width = 1280 }
            m.addMagicPrompt("slow-mo moment", tab: .chatgpt)
            m.addMagicPrompt(" make a quick cut ", tab: .claude)
            m.undo()
            let order = m.magicHistory.map(\.text) == ["make a quick cut", "slow-mo moment"] && m.magicHistory[0].tab == "claude"
            let saved = (try? JSONEncoder().encode(m.project)).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
            let file = saved?.magicHistory?.map(\.text) == m.magicHistory.map(\.text)
            let old = (try? JSONEncoder().encode(Project())).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
            let opensOld = old != nil && old?.magicHistory == nil && EditorModel().magicHistory.isEmpty
            for i in 0..<25 { m.addMagicPrompt("prompt \(i)", tab: .local) }
            let capped = m.magicHistory.count == MagicHistory.limit && m.magicHistory[0].text == "prompt 24"
            let good = order && file && opensOld && capped
            log("HISTORY \(good ? "OK" : "FAIL") order=\(order) file=\(file) opensOld=\(opensOld) capped=\(capped)")
            ok = ok && good
        }
        // An AI's edit, played as its result: an AI adds clips one after another, each at full length then
        // trimmed (so played in order every step waits for the last). As a result the new clips all fly in
        // at once, and the show still ends exactly where the AI's edits do.
        do {
            var p = Project()
            let v1 = p.videoTracks[0].id, a2 = p.audioTracks[1].id
            let old = Clip(trackID: v1, kind: .solid, start: 0, duration: 3)
            let music = Clip(trackID: a2, kind: .audio, start: 0, duration: 20)
            p.clips = [old, music]
            var edits: [MagicEdit] = [.remove([old.id])]
            var t = 0.0
            for _ in 0..<6 {
                let c = Clip(trackID: v1, kind: .solid, start: t, duration: 5)
                edits.append(.place([c], asset: nil))
                edits.append(.trimTail([c.id], from: t + 5, to: t + 1))
                edits.append(.fadeIn(c.id, to: 0.2))
                t += 1
            }
            edits.append(.gain(music.id, from: 0, to: -6))
            var final = p
            for e in edits { e.apply(&final, 1) }
            let stepPlan = MCPDraft.plan(base: p, edits: edits)
            let resultPlan = MCPDraft.resultPlan(base: p, edits: edits)
            var played = resultPlan.base
            for task in resultPlan.tasks { task.edit.apply(&played, 1) }
            let same = Dictionary(played.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                == Dictionary(final.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // The longest line of edits each waiting for the one before: short means many cursors at once.
            func depth(_ plan: MagicPlan) -> Int {
                var d: [Int] = []
                for t in plan.tasks { d.append(1 + (t.after.map { d[$0] }.max() ?? 0)) }
                return d.max() ?? 0
            }
            let wider = depth(resultPlan) <= 4 && depth(resultPlan) < depth(stepPlan)
            let good = same && wider
            log("AI RESULT SHOW \(good ? "OK" : "FAIL") same=\(same) depth=\(depth(resultPlan)) (was \(depth(stepPlan))) tasks=\(resultPlan.tasks.count)")
            ok = ok && good
        }
        // Media search in everyday words: "ride" finds a rollercoaster, "party" a celebration, "city" a cityscape;
        // a word nothing means finds nothing.
        do {
            func tags(_ names: String...) -> SceneTags { SceneTags(tags: names.map { SceneTags.Tag(name: $0, confidence: 0.9, times: [1]) }) }
            let ride = tags("rollercoaster").shows("ride") && tags("amusement park").shows("rides") && tags("carousel").shows("ride")
            let party = tags("celebration").shows("party") && tags("cityscape").shows("city") && tags("surfing").shows("waves")
            let still = tags("dog").shows("puppy") && !tags("dog").shows("ride") && !tags("rollercoaster").shows("laughing")
            let vehicle = tags("car").shows("vehicle") && tags("boat").shows("vehicles") && tags("airplane").shows("vehicle") && tags("bus").shows("vehicle")
            let good = ride && party && still && vehicle && SceneTags.aliases.count > 100
            log("SEARCH WORDS \(good ? "OK" : "FAIL") ride=\(ride) vehicle=\(vehicle) everyday=\(party) unchanged=\(still) labels=\(SceneTags.aliases.count)")
            ok = ok && good
        }
        // @ markers: by name or @marker:, unnamed ones by colour, read as their times (a span, a title's place),
        // and a file of the same name wins over a marker.
        do {
            var p = Project()
            p.clips = [Clip(trackID: p.videoTracks[0].id, kind: .video, start: 0, duration: 30)]
            p.markers = [Marker(time: 12.4, name: "Jump"), Marker(time: 20, name: "", tint: .green), Marker(time: 25, name: "Big drop")]
            let marks = MagicMention.markerLabels(p)
            let labels = marks.map(\.name) == ["Jump", "Green marker", "Big drop"]
            func isMarker(_ text: String) -> Bool {
                MagicMention.find(in: text, media: p.assets, markers: marks).contains { if case .marker = $0.mention { return true } else { return false } }
            }
            let found = isMarker("title at @Jump") && isMarker("at @marker:Green marker") && isMarker("from @big drop on") && !isMarker("email me@Jump")
            let timed = MagicMention.markersAsTimes("slow-mo from @Jump to @marker:Green marker", project: p)
            let span = MagicTimes.span(in: timed, fps: p.fps)
            let spanOK = timed == "slow-mo from 0:12.4 to 0:20" && span.map { abs($0.start - 12.4) < 0.01 && abs($0.end - 20) < 0.01 } ?? false
            let titleReq = MagicMention.markersAsTimes("add a title at @Big drop", project: p)
            var titleAt = -1.0
            if let plan = LocalTitle.plan(request: titleReq, playhead: 0, project: p).plan {
                var q = plan.base
                for t in plan.tasks { t.edit.apply(&q, 1) }
                titleAt = q.clips.first { $0.kind == .text }?.start ?? -1
            }
            let titleOK = abs(titleAt - 25) < 0.05
            var withFile = p
            withFile.assets = [MediaAsset(path: "/tmp/Jump.mov", name: "Jump.mov", kind: .video, duration: 5, width: 1920, height: 1080, fps: 30, hasAudio: false)]
            let fileWins = MagicMention.find(in: "use @Jump", media: withFile.assets, markers: marks).first.map { if case .media = $0.mention { return true } else { return false } } ?? false
            let good = labels && found && spanOK && titleOK && fileWins
            log("MARKER MENTIONS \(good ? "OK" : "FAIL") labels=\(labels) found=\(found) span=\(spanOK) (\(timed)) title=\(titleOK) at \(titleAt) fileWins=\(fileWins)")
            ok = ok && good
        }
        // Local titles on an edit: at the end (default words), and their own words at the start.
        do {
            var p = Project()
            p.clips = [Clip(trackID: p.videoTracks[0].id, kind: .video, start: 0, duration: 10)]
            func titled(_ request: String) -> Clip? {
                guard LocalTitle.asks(request, project: p), let plan = LocalTitle.plan(request: request, playhead: 0, project: p).plan else { return nil }
                var q = plan.base
                for t in plan.tasks { t.edit.apply(&q, 1) }
                return q.clips.first { $0.kind == .text }
            }
            let end = titled("add vlog title screen at the end")
            let endOK = end.map { abs($0.end - 10) < 0.05 && $0.text.string == "Title" && $0.trackID == p.videoTracks[1].id } ?? false
            let start = titled("put a title saying \"Day one\" at the start")
            let startOK = start.map { $0.start == 0 && $0.text.string == "Day one" } ?? false
            let newCut = !LocalTitle.asks("make a new montage with a title", project: p)
            let good = endOK && startOK && newCut
            log("LOCAL TITLE \(good ? "OK" : "FAIL") end=\(endOK) start=\(startOK) newCut=\(newCut)")
            ok = ok && good
        }
        // Typed timecodes.
        do {
            let cases: [(String, Double?)] = [("1000", 10), ("1:02:03", 62.1), ("00:00:02:15", 2.5), ("12", 0.4), ("abc", nil)]
            let good = cases.allSatisfy { c in
                let v = Timecode.parse(c.0, fps: 30)
                return c.1 == nil ? v == nil : v.map { abs($0 - c.1!) < 1e-9 } ?? false
            }
            log("TIMECODE \(good ? "OK" : "FAIL")")
            ok = ok && good
        }
        // Transition timing: the dissolve borrows the sped-up clip's unused head and ends at the cut;
        // a dip sits across the cut; with no spare media at all, a dissolve uses what there is.
        do {
            var p = Project()
            let v = p.videoTracks[0].id
            let a = Clip(trackID: v, kind: .video, start: 0, duration: 2)
            var b = Clip(trackID: v, kind: .video, start: 2, duration: 1, sourceStart: 2, speed: 4)
            b.transitionIn = Transition(kind: .dissolve, duration: 0.5)
            p.clips = [a, b]
            let span = p.transitionSpan(from: a, into: b)
            let headOK = span.map { abs($0.start - 1.5) < 1e-9 && $0.end == 2 && $0.fromHead } ?? false
            let plan = p.transitionPlan(b)
            let planOK = abs(plan.leadIn - 0.5) < 1e-9 && plan.reveal?.start == 1.5
            p.clips[1].transitionIn = Transition(kind: .dipToBlack, duration: 1)
            let dip = p.transitionSpan(from: a, into: p.clips[1])
            let dipOK = dip.map { $0.start == 1.5 && $0.end == 2.5 } ?? false
            let concealOK = p.transitionPlan(a).conceal?.end == 2
            let good = headOK && planOK && dipOK && concealOK
            log("TRANSITIONS \(good ? "OK" : "FAIL") head=\(headOK) plan=\(planOK) dip=\(dipOK) conceal=\(concealOK)")
            ok = ok && good
        }
        // Ducking: A2 (the tone) turned down while A1 has sound; checked by comparing files.
        do {
            var ducked = project
            ducked.audioTracks[1].duckUnder = ducked.audioTracks[0].id
            ducked.audioTracks[1].duckDB = -18
            var settings = ExportSettings()
            settings.format = .wav
            _ = await export(ducked, media, settings, to: outDir.appendingPathComponent("ducked.wav"))
            let spans = AudioLevels.activity(on: project.audioTracks[0].id, project: project, media: media)
            log("DUCK spans=\(spans.map { String(format: "%.2f-%.2f", $0.start, $0.end) })")
        }
        // Loudness: a WAV exported at -14 LUFS, measured again from the file.
        do {
            var settings = ExportSettings()
            settings.format = .wav
            settings.loudness = -14
            let url = outDir.appendingPathComponent("loud_14.wav")
            _ = await export(project, media, settings, to: url)
            let check = AVURLAsset(url: url)
            let comp = AVMutableComposition()
            if let src = try? await check.loadTracks(withMediaType: .audio).first, let range = try? await src.load(.timeRange),
               let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? t.insertTimeRange(range, of: src, at: .zero)
            }
            let measured = LoudnessMeter.measure(BuiltTimeline(composition: comp, videoComposition: AVMutableVideoComposition(),
                                                               audioMix: nil, duration: 0, signature: 0, hasAudio: true))
            let good = measured.map { abs($0.lufs + 14) < 0.6 || $0.peakDB > -1.3 } ?? false
            log("LOUDNESS \(good ? "OK" : "FAIL") lufs=\(measured.map { String(format: "%.2f", $0.lufs) } ?? "-") peak=\(measured.map { String(format: "%.2f", $0.peakDB) } ?? "-")")
            ok = ok && good
        }
        // Text and solids land in the first open spot: a free track at the playhead, else the next gap.
        do {
            var p = Project()
            let v1 = p.videoTracks[0].id, v2 = p.videoTracks[1].id
            p.clips = [Clip(trackID: v1, kind: .solid, start: 0, duration: 10)]
            let up = p.firstFreeVideoSpot(from: 2, duration: 5)
            p.clips.append(Clip(trackID: v2, kind: .solid, start: 1, duration: 3))
            let right = p.firstFreeVideoSpot(from: 2, duration: 5)
            let good = up.map { $0.track == v2 && $0.start == 2 } == true && right.map { $0.track == v2 && $0.start == 4 } == true
            log("PLACEMENT \(good ? "OK" : "FAIL")")
            ok = ok && good
        }
        // Audio scrubbing: the edit's mix is rendered into memory, with sound where the edit has it and
        // silence after the end.
        do {
            let scrubber = AudioScrubber()
            scrubber.prepare(project: project, media: media)
            var waited = 0
            while !scrubber.ready, waited < 100 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
            let mid = scrubber.peak(at: 1.5), late = scrubber.peak(at: project.duration + 1)
            let good = scrubber.ready && mid > 0.01 && late == 0
            log("AUDIO SCRUB \(good ? "OK" : "FAIL") ready=\(scrubber.ready) after=\(waited * 50)ms peak=\(mid) end=\(late)")
            ok = ok && good
        }
        // Meters: lit while playing, and empty the moment playback stops (no lingering levels or red).
        do {
            let meters = MeterState()
            var loud = project
            loud.audioTracks[1].gainDB = 30
            for _ in 0..<5 { meters.update(project: loud, media: media, time: 2.0, playing: true) }
            let lit = meters.master.level > -20 && meters.master.clipped
            meters.update(project: loud, media: media, time: 2.0, playing: false)
            let empty = meters.master.level == MeterState.floor && !meters.master.clipped && meters.tracks.values.allSatisfy { $0.level == MeterState.floor && $0.peak == MeterState.floor }
            log("METERS \(lit && empty ? "OK" : "FAIL") lit=\(lit) emptyOnStop=\(empty)")
            ok = ok && lit && empty
        }
        // Gaps and pasting: a gap closes with linked audio following; all gaps close; paste makes fresh,
        // still-linked copies at the playhead.
        do {
            var p = Project()
            let v = p.videoTracks[0].id, a = p.audioTracks[0].id
            let link = UUID()
            let c1 = Clip(trackID: v, kind: .solid, start: 0, duration: 2)
            let c2 = Clip(trackID: v, kind: .video, start: 3, duration: 2, linkID: link)
            let c2a = Clip(trackID: a, kind: .audio, start: 3, duration: 2, linkID: link)
            let c3 = Clip(trackID: v, kind: .solid, start: 6, duration: 1)
            p.clips = [c1, c2, c3, c2a]
            let g = p.gap(on: v, at: 2.5)
            var q = p
            q.pullLeft(on: v, from: 3, by: 1)
            let closed = g.map { $0.start == 2 && $0.end == 3 } == true && q.clip(c2.id)?.start == 2 && q.clip(c2a.id)?.start == 2 && q.clip(c3.id)?.start == 5
            var r = p
            r.closeAllGaps(on: v)
            let all = r.clip(c2.id)?.start == 2 && r.clip(c3.id)?.start == 4
            let m = EditorModel()
            m.load(p, url: nil)
            m.selection = [c2.id]
            m.copySelection()
            m.seek(to: 10)
            m.paste()
            let pasted = m.project.clips.filter { $0.start == 10 }
            let pasteOK = pasted.count == 2 && Set(pasted.map(\.linkID)).count == 1 && pasted[0].linkID != link && !pasted.contains { $0.id == c2.id }
            log("GAPS+PASTE \(closed && all && pasteOK ? "OK" : "FAIL") gap=\(closed) all=\(all) paste=\(pasteOK)")
            ok = ok && closed && all && pasteOK
        }
        // Freeze frame: the clip splits at the playhead, a 2s hold goes in and the rest moves along;
        // exported frames across the hold are identical.
        if let video = project.assets.first(where: { $0.kind == .video && $0.duration >= 6 }) {
            var p = Project()
            p.width = 640; p.height = 360; p.fps = 30
            p.assets = project.assets
            let v = p.videoTracks[0].id
            p.clips = [Clip(trackID: v, kind: .video, assetID: video.id, start: 0, duration: 4)]
            let m = EditorModel()
            m.load(p, url: nil)
            m.seek(to: 1)
            m.freezeFrame()
            let parts = m.project.clips.sorted { $0.start < $1.start }.map { ($0.start, $0.end, $0.isFreeze) }
            let shape = parts.count == 3 && parts[1] == (1, 3, true) && parts[2].0 == 3 && abs(parts[2].1 - 6) < 1e-9
            let url = outDir.appendingPathComponent("freeze.mp4")
            var settings = ExportSettings()
            settings.includeAudio = false
            _ = await export(m.project, media, settings, to: url)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            func bytes(_ t: Double) async -> [UInt8] {
                guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                      let data = cg.dataProvider?.data as Data? else { return [] }
                return Array(data)
            }
            func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
                guard !a.isEmpty, a.count == b.count else { return 999 }
                var sum = 0
                for i in stride(from: 0, to: a.count, by: 7) { sum += abs(Int(a[i]) - Int(b[i])) }
                return Double(sum) / Double(a.count / 7)
            }
            let f1 = await bytes(1.3), f2 = await bytes(2.7), moving = await bytes(4.5)
            let held = diff(f1, f2) < 2 && diff(f1, moving) > 2
            log("FREEZE \(shape && held ? "OK" : "FAIL") shape=\(shape) held=\(held) d=\(diff(f1, f2)) vs \(diff(f1, moving))")
            ok = ok && shape && held
        }
        // Reverse: a reversed clip's first frame is the last of its stretch of the file and its last
        // frame the first, its length is unchanged, and its sound comes along.
        if let video = project.assets.first(where: { $0.kind == .video && $0.duration >= 6 && $0.hasAudio }),
           let v1 = project.videoTracks.first, let a1 = project.audioTracks.first {
            var p = project
            p.clips = []
            let link = UUID()
            var v = Clip(trackID: v1.id, kind: .video, assetID: video.id, start: 0, duration: 3, sourceStart: 1)
            var a = Clip(trackID: a1.id, kind: .audio, assetID: video.id, start: 0, duration: 3, sourceStart: 1)
            v.linkID = link; a.linkID = link
            for c in [v, a] {
                var r = c
                r.sourceStart = video.duration - (c.sourceStart + c.duration)
                r.reversed = true
                p.clips.append(r)
            }
            let out = outDir.appendingPathComponent("reversed.mp4")
            var settings = ExportSettings()
            settings.height = 360
            _ = await export(p, media, settings, to: out)
            let rev = AVURLAsset(url: out), src = AVURLAsset(url: video.url)
            let length = (try? await rev.load(.duration).seconds) ?? 0
            func frame(_ a: AVAsset, _ t: Double) async -> [UInt8] {
                let g = AVAssetImageGenerator(asset: a)
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                g.maximumSize = CGSize(width: 160, height: 90)
                guard let cg = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                      let d = cg.dataProvider?.data as Data? else { return [] }
                return Array(d)
            }
            func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
                guard !a.isEmpty, a.count == b.count else { return 999 }
                var s = 0; for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }; return Double(s) / Double(a.count)
            }
            let startMatch = diff(await frame(rev, 0.02), await frame(src, 3.97))
            let endMatch = diff(await frame(rev, 2.95), await frame(src, 1.02))
            let wrongWay = diff(await frame(rev, 0.02), await frame(src, 1.02))
            let audio = ((try? await rev.loadTracks(withMediaType: .audio))?.count ?? 0) == 1
            let good = abs(length - 3) < 0.1 && startMatch < 8 && endMatch < 8 && wrongWay > startMatch && audio
            log("REVERSE \(good ? "OK" : "FAIL") length=\(length) start=\(startMatch) end=\(endMatch) forwards=\(wrongWay) audio=\(audio)")
            ok = ok && good
        }
        // In/out: exporting just the range gives a file the range's length, and markers survive saving.
        do {
            var p = project
            p.inPoint = 1
            p.outPoint = 2.5
            p.markers = [Marker(time: 1.2, name: "Beat drop", tint: .green)]
            var settings = ExportSettings()
            settings.includeAudio = true
            settings.height = 360
            settings.rangeOnly = true
            let url = outDir.appendingPathComponent("range.mp4")
            _ = await export(p, media, settings, to: url)
            let length = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.timeRange).duration.seconds) ?? 0
            let back = (try? JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p)))
            let kept = back?.markers?.first?.name == "Beat drop" && back?.inPoint == 1 && back?.outPoint == 2.5
            var old = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
            old?["markers"] = nil
            let opensOld = old.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSONDecoder().decode(Project.self, from: $0) } != nil
            let snaps = p.snapTargets(excluding: []).contains(1.2)
            let good = abs(length - 1.5) < 0.06 && kept && opensOld && snaps
            log("RANGE \(good ? "OK" : "FAIL") length=\(length) kept=\(kept) opensOld=\(opensOld) snaps=\(snaps)")
            ok = ok && good
        }
        // Sticky trims: a left edge counts as attached at time zero or against a clip, not in the open.
        do {
            var p = Project()
            p.videoTracks = [Track(kind: .video)]
            let v = p.videoTracks[0].id
            let a = Clip(trackID: v, kind: .solid, start: 0, duration: 2)
            let b = Clip(trackID: v, kind: .solid, start: 2, duration: 2)
            let free = Clip(trackID: v, kind: .solid, start: 6, duration: 2)
            p.clips = [a, b, free]
            let good = TimelineCanvas.attachedOnLeft([a], in: p) && TimelineCanvas.attachedOnLeft([b], in: p) && !TimelineCanvas.attachedOnLeft([free], in: p)
            log("STICKY EDGE \(good ? "OK" : "FAIL")")
            ok = ok && good
        }
        // Film print: the app's Look gives the same colours as the mock it was approved from.
        do {
            let cases: [((Double, Double, Double), (Double, Double, Double))] = [
                ((0.80, 0.55, 0.42), (0.8603, 0.6593, 0.5182)),
                ((0.70, 0.10, 0.12), (0.6969, 0.1364, 0.1386)),
                ((0.20, 0.50, 0.25), (0.3269, 0.5724, 0.3360)),
                ((0.50, 0.50, 0.50), (0.6021, 0.5987, 0.5938)),
                ((0.10, 0.12, 0.20), (0.1167, 0.1203, 0.1584)),
                ((0.95, 0.93, 0.90), (0.9350, 0.9800, 0.9546)),
            ]
            let worst = cases.map { input, want in
                let got = LookMath.filmPrint(input)
                return max(abs(got.0 - want.0), abs(got.1 - want.1), abs(got.2 - want.2))
            }.max() ?? 1
            let good = worst < 0.002 && BuiltInLook.named("Film print") != nil
            log("FILM PRINT \(good ? "OK" : "FAIL") worst=\(String(format: "%.4f", worst))")
            ok = ok && good
        }
        // Copy and paste grade: the whole grade goes onto every selected visual clip (not sound), and
        // one undo puts them all back.
        do {
            var p = Project()
            let v = p.videoTracks[0].id, au = p.audioTracks[0].id
            var graded = Clip(trackID: v, kind: .solid, start: 0, duration: 2)
            var g = ColorGrade()
            g.look = "Warm film"
            g.lookIntensity = 0.6
            g.exposure = 0.4
            g.saturation = -12
            graded.grade = g
            var other = Clip(trackID: v, kind: .solid, start: 2, duration: 2)
            var og = ColorGrade()
            og.exposure = -1
            other.grade = og
            let plain = Clip(trackID: v, kind: .text, start: 4, duration: 2)
            let sound = Clip(trackID: au, kind: .audio, start: 0, duration: 2)
            p.clips = [graded, other, plain, sound]
            let m = EditorModel()
            m.load(p, url: nil)
            m.selection = [graded.id]
            let canCopy = m.canCopyGrade
            m.copyGrade()
            m.selection = [other.id, plain.id, sound.id]
            let canPaste = m.canPasteGrade
            m.pasteGrade()
            let pasted = m.project.clip(other.id)?.grade == g && m.project.clip(plain.id)?.grade == g && m.project.clip(sound.id)?.grade == nil
            m.undo()
            let undone = m.project.clip(other.id)?.grade == og && m.project.clip(plain.id)?.grade == nil
            let good = canCopy && canPaste && pasted && undone
            log("GRADE PASTE \(good ? "OK" : "FAIL") copy=\(canCopy) paste=\(canPaste) pasted=\(pasted) undo=\(undone)")
            ok = ok && good
        }
        // Export shapes: a vertical 9:16 export is 1080 × 1920, and moving the crop changes what's kept.
        do {
            var settings = ExportSettings()
            settings.includeAudio = false
            settings.height = 1080
            settings.shape = .vertical
            settings.reframe = CGPoint(x: 0.1, y: 0.5)
            let left = outDir.appendingPathComponent("vertical_left.mp4"), right = outDir.appendingPathComponent("vertical_right.mp4")
            _ = await export(project, media, settings, to: left)
            settings.reframe = CGPoint(x: 0.9, y: 0.5)
            _ = await export(project, media, settings, to: right)
            func probe(_ url: URL) async -> (CGSize, [UInt8]) {
                let a = AVURLAsset(url: url)
                let size = (try? await a.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
                let g = AVAssetImageGenerator(asset: a)
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                g.maximumSize = CGSize(width: 90, height: 160)
                let cg = try? await g.image(at: CMTime(seconds: 1.0, preferredTimescale: 600)).image
                return (size, cg.flatMap { $0.dataProvider?.data as Data? }.map { Array($0) } ?? [])
            }
            let (ls, lb) = await probe(left), (rs, rb) = await probe(right)
            var d = 0.0
            if !lb.isEmpty, lb.count == rb.count { d = Double(zip(lb, rb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(lb.count) }
            let good = ls == CGSize(width: 1080, height: 1920) && rs == ls && d > 10
            log("SHAPES \(good ? "OK" : "FAIL") size=\(ls) leftVsRight=\(d)")
            ok = ok && good
        }
        // Auto planner: finds the beat of a 128 BPM track, cuts the test clips on its beats, never
        // reuses a moment, ends on a bar; the choreographed edits build exactly that cut, graded,
        // with a title.
        do {
            let rate = 22050.0, bpm = 128.0, seconds = 40.0
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let song = outDir.appendingPathComponent("beat128.caf")
            try? FileManager.default.removeItem(at: song)
            if let file = try? AVAudioFile(forWriting: song, settings: format.settings),
               let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)) {
                buf.frameLength = buf.frameCapacity
                let x = buf.floatChannelData![0]
                let period = 60 / bpm
                for i in 0..<Int(buf.frameLength) {
                    let t = Double(i) / rate
                    let beat = Int(t / period), into = t - Double(beat) * period
                    // A kick on every beat (harder on the first of each bar) and a quiet hat between.
                    let kick = exp(-into * 30) * sin(2 * .pi * 55 * into) * (beat % 4 == 0 ? 0.9 : 0.6)
                    let hatAt = into - period / 2
                    let hat = hatAt > 0 ? exp(-hatAt * 80) * Double.random(in: -0.15...0.15) : 0
                    x[i] = Float(kick + hat)
                }
                try? file.write(from: buf)
            }
            let music = await MediaAnalyzer.music(song)
            var clips: [(MediaAsset, ClipAnalysis)] = []
            for a in project.assets where a.kind == .video {
                if let c = await MediaAnalyzer.clip(a.url, kind: .video) { clips.append((a, c)) }
            }
            var songAsset = MediaAsset(path: song.path, name: "beat128", kind: .audio, duration: seconds, width: 0, height: 0, fps: 0, hasAudio: true)
            songAsset.duration = seconds
            var plan = project
            plan.clips = []
            plan.assets.append(songAsset)
            let decision = music.flatMap { m in AutoPlanner.decide(project: plan, clips: clips, music: (songAsset, m)) }
            var good = false
            var detail = "no plan"
            if let m = music, let d = decision, let dm = d.music {
                let tempoOK = abs(m.bpm - bpm) < 1.5
                let gaps = zip(m.beats.dropFirst(), m.beats).map { $0 - $1 }
                let steady = gaps.allSatisfy { abs($0 - 60 / bpm) < 0.03 }
                    // On the kicks, not between them.
                    && m.beats.allSatisfy { b in
                        let off = b.truncatingRemainder(dividingBy: 60 / bpm)
                        return min(off, 60 / bpm - off) < 0.04
                    }
                // Every cut is on a beat of the song.
                var at = 0.0
                var onBeat = true
                for s in d.shots {
                    at += s.duration
                    let songTime = dm.source + at
                    onBeat = onBeat && m.beats.contains { abs($0 - songTime) < 0.002 }
                }
                let firstBeat = m.beats.firstIndex { abs($0 - dm.source) < 0.002 } ?? -1
                let lastBeat = m.beats.firstIndex { abs($0 - (dm.source + at)) < 0.002 } ?? -1
                // Bars start on the accented kick.
                let barTime = m.beats[m.barPhase].truncatingRemainder(dividingBy: 4 * 60 / bpm)
                let downbeatOK = min(barTime, 4 * 60 / bpm - barTime) < 0.04
                let onBar = downbeatOK && firstBeat >= 0 && m.isBarStart(firstBeat) && (lastBeat - firstBeat) % 4 == 0
                let inside = d.shots.allSatisfy { $0.source >= 0 && $0.source + $0.duration <= $0.asset.duration + 0.001 }
                var clash = false
                for (i, a) in d.shots.enumerated() {
                    for b in d.shots[(i + 1)...] where a.asset.id == b.asset.id {
                        if a.source < b.source + b.duration && b.source < a.source + a.duration { clash = true }
                    }
                }
                // The choreographed edits, all done, make that cut.
                var built = false
                if let choreo = Choreographer.plan(project: plan, decision: d) {
                    var p = choreo.base
                    for t in choreo.tasks { t.edit.apply(&p, 1) }
                    let v1 = p.videoTracks[0].id
                    let shots = p.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
                    let gapless = zip(shots.dropFirst(), shots).allSatisfy { abs($0.start - $1.end) < 1e-6 }
                    built = shots.count == d.shots.count && gapless && shots.allSatisfy { ($0.grade?.look ?? "") == d.look }
                        // No title unless one was asked for.
                        && (d.title.isEmpty ? !p.clips.contains { $0.kind == .text } : p.clips.contains { $0.kind == .text && $0.text.string == d.title })
                        && LocalBrain.titleAsked("make a fast cut") == nil && LocalBrain.titleAsked("add a title") == ""
                        && LocalBrain.titleAsked("put a title saying \"Summer '26\" on it")?.hasPrefix("Summer") == true
                        && LocalBrain.titleAsked("make it without a title") == nil
                        && p.clips.contains { $0.assetID == songAsset.id }
                }
                good = tempoOK && steady && onBeat && onBar && inside && !clash && built && d.shots.count >= 2
                detail = String(format: "bpm=%.1f beats=%d steady=%@ shots=%d onBeat=%@ onBar=%@ inside=%@ clash=%@ built=%@",
                                m.bpm, m.beats.count, "\(steady)", d.shots.count, "\(onBeat)", "\(onBar)", "\(inside)", "\(clash)", "\(built)")
            }
            log("AUTO PLAN \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // MCP tools: an agent adds two clips, trims, splits, grades, adds a dissolve and deletes with
        // ripple; each call is one undo step; bad input is a clear error, not a crash.
        do {
            let m = EditorModel()
            var p = Project()
            p.assets = project.assets.filter { $0.kind == .video }
            m.load(p, url: nil)
            func call(_ name: String, _ args: [String: Any]) async -> (Any?, String?) {
                do {
                    let out = try await MCPTools.call(name, args, model: m, client: nil)
                    let text = out.first?["text"] as? String ?? ""
                    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), nil)
                } catch {
                    return (nil, (error as? MCPToolError)?.message ?? "\(error)")
                }
            }
            var good = false
            var detail = ""
            if let asset = p.assets.first(where: { $0.hasAudio && $0.duration >= 4 }) {
                let (a, _) = await call("add_clip", ["asset_id": asset.id.uuidString, "duration": 3.0])
                let (b, _) = await call("add_clip", ["asset_id": asset.id.uuidString, "source_start": 1.0, "duration": 2.0])
                let first = ((a as? [String: Any])?["added"] as? [[String: Any]])?.first?["id"] as? String ?? ""
                let second = ((b as? [String: Any])?["added"] as? [[String: Any]])?.first?["id"] as? String ?? ""
                _ = await call("trim_clip", ["clip_id": first, "end": 2.5])
                _ = await call("set_transition", ["clip_id": second, "kind": "dissolve", "duration": 0.4])
                _ = await call("set_grade", ["clip_ids": [second], "look": "Mono", "exposure": 0.3])
                let (split, _) = await call("split_clip", ["clip_id": second, "at": 4.0])
                let right = ((split as? [String: Any])?["right"] as? [[String: Any]])?.first?["id"] as? String ?? ""
                _ = await call("delete_clips", ["clip_ids": [right], "ripple": true])
                let (_, bad) = await call("move_clip", ["clip_id": "nope", "start": 1.0])
                let q = m.project
                let v1 = q.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
                let shapeOK = v1.count == 2 && abs(v1[0].end - 2.5) < 1e-6 && abs(v1[1].start - 3) < 1e-6 && abs(v1[1].end - 4) < 1e-6
                let gradeOK = v1.last?.grade?.look == "Mono" && abs((v1.last?.grade?.exposure ?? 0) - 0.3) < 1e-9
                let audioOK = q.clips.filter { $0.kind == .audio }.count == 2
                // Seven changes, seven undos back to empty.
                for _ in 0..<7 { m.undo() }
                let undoOK = m.project.clips.isEmpty
                good = shapeOK && gradeOK && audioOK && undoOK && bad != nil
                detail = "v1=\(v1.map { "\($0.start)-\($0.end)" }) grade=\(gradeOK) audio=\(audioOK) undo=\(undoOK) error=\(bad ?? "none")"
            }
            log("MCP TOOLS \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // The newer MCP tools: markers and in/out, reframing, title style, solids, freeze, reverse, detach,
        // duplicate, track switches, search and export; each change one undo step; export refused in Magic.
        do {
            let m = EditorModel()
            var p = Project()
            p.assets = project.assets.filter { $0.kind == .video }
            m.load(p, url: nil)
            m.setExportTarget(name: "selftest", directory: outDir.path)
            func call(_ name: String, _ args: [String: Any], draft: MCPDraft? = nil) async -> (Any?, String?) {
                do {
                    let out = try await MCPTools.call(name, args, model: m, client: nil, draft: draft)
                    let text = out.first?["text"] as? String ?? ""
                    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), nil)
                } catch {
                    return (nil, (error as? MCPToolError)?.message ?? "\(error)")
                }
            }
            func id(_ r: Any?) -> String {
                if let d = r as? [String: Any] {
                    if let added = d["added"] as? [[String: Any]] { return added.first?["id"] as? String ?? "" }
                    if let added = d["added"] as? [String: Any] { return added["id"] as? String ?? "" }
                    return d["id"] as? String ?? ""
                }
                return (r as? [[String: Any]])?.first?["id"] as? String ?? ""
            }
            var checks: [String: Bool] = [:]
            if let asset = p.assets.first(where: { $0.hasAudio && $0.duration >= 4 }) {
                let a = id(await call("add_clip", ["asset_id": asset.id.uuidString, "duration": 3.0]).0)
                let aID = UUID(uuidString: a)
                // Markers and in/out.
                let mk = id(await call("set_marker", ["time": 1.0, "name": "Beat", "color": "red"]).0)
                _ = await call("set_marker", ["marker_id": mk, "name": "Drop"])
                _ = await call("set_marker", ["time": 2.0])
                checks["markers"] = m.project.markerList.map(\.name) == ["Drop", "Marker 2"] && m.project.markerList.first?.tint == .red
                _ = await call("delete_markers", ["marker_ids": [mk]])
                checks["delete"] = m.project.markerList.count == 1
                _ = await call("set_in_out", ["in": 0.5, "out": 2.5])
                checks["in_out"] = m.project.playRange.map { abs($0.start - 0.5) < 0.02 && abs($0.end - 2.5) < 0.02 } ?? false
                // Reframing, a styled title, a solid.
                _ = await call("set_transform", ["clip_id": a, "scale": 1.5, "x": 0.1])
                checks["transform"] = m.project.clip(aID ?? UUID())?.transform.map { $0.scale == 1.5 && $0.x == 0.1 } ?? false
                let t = id(await call("add_title", ["text": "Hi", "start": 0.0, "duration": 1.0]).0)
                let (_, badFont) = await call("set_title_style", ["clip_id": t, "font": "No Such Font Anywhere"])
                _ = await call("set_title_style", ["clip_id": t, "text": "Hello", "size": 80.0, "color": "#FF0000", "x": 0.3, "bold": false])
                let title = UUID(uuidString: t).flatMap { m.project.clip($0) }
                checks["title"] = title.map { $0.text.string == "Hello" && $0.text.size == 80 && $0.text.color.r == 1 && $0.text.color.g == 0 && $0.text.x == 0.3 && !$0.text.bold } ?? false
                checks["bad_font"] = badFont != nil
                if checks["title"] != true, let tt = title { log("MCP MORE title: \(tt.text.string) size \(tt.text.size) colour \(MCPTools.hex(tt.text.color)) x \(tt.text.x) bold \(tt.text.bold)") }
                let s = id(await call("add_solid", ["color": "#112233", "start": 5.0, "duration": 1.0]).0)
                _ = await call("set_solid_color", ["clip_id": s, "color": "#445566"])
                checks["solid"] = UUID(uuidString: s).flatMap { m.project.clip($0) }.map { $0.kind == .solid && MCPTools.hex($0.color) == "#445566" } ?? false
                // Freeze, reverse, detach, duplicate.
                let videoBefore = m.project.clips.filter { $0.kind == .video }.map(\.end).max() ?? 0
                _ = await call("freeze_frame", ["clip_id": a, "at": 1.0, "seconds": 1.0])
                let videoAfter = m.project.clips.filter { $0.kind == .video }.map(\.end).max() ?? 0
                checks["freeze"] = m.project.clips.contains { $0.isFreeze } && abs(videoAfter - videoBefore - 1) < 0.05
                _ = await call("reverse_clip", ["clip_id": a])
                checks["reverse"] = m.project.clip(aID ?? UUID())?.playsBackwards == true
                _ = await call("detach_audio", ["clip_id": a])
                checks["detach"] = m.project.clip(aID ?? UUID())?.linkID == nil
                _ = await call("duplicate_clip", ["clip_id": a, "start": 12.0])
                checks["duplicate"] = m.project.clips.contains { $0.kind == .video && abs($0.start - 12) < 0.02 }
                // Track switches.
                _ = await call("set_track", ["track": "A1", "muted": true, "gain_db": -3.0])
                checks["track"] = m.project.audioTracks.first.map { $0.muted && $0.gainDB == -3 } ?? false
                // Search: nothing shows a made-up word; asking for nothing is an error.
                let (found, _) = await call("search_media", ["shows": "zzqqxx"])
                let (_, empty) = await call("search_media", [:])
                checks["search"] = ((found as? [String: Any])?["found"] as? [Any])?.isEmpty == true && empty != nil
                // Export: a small file, waited for, in the folder set for it; refused during Magic.
                let draft = MCPDraft.open(m.project)
                let (_, refused) = await call("export", ["name": "mcp-export"], draft: draft)
                draft.close()
                let (made, exportError) = await call("export", ["name": "mcp-export", "height": 360, "wait": true])
                let file = (made as? [String: Any])?["file"] as? String ?? ""
                checks["export"] = exportError == nil && (made as? [String: Any])?["status"] as? String == "done" && FileManager.default.fileExists(atPath: file)
                    && file.hasPrefix(outDir.path)
                checks["export_refused_in_magic"] = refused != nil
                try? FileManager.default.removeItem(atPath: file)
                // Every change undoes: back to an empty timeline with no markers or range.
                for _ in 0..<40 where m.canUndo { m.undo() }
                checks["undo"] = m.project.clips.isEmpty && m.project.markers == nil && m.project.playRange == nil
            }
            let good = !checks.isEmpty && checks.values.allSatisfy { $0 }
            log("MCP MORE \(good ? "OK" : "FAIL") " + checks.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            ok = ok && good
        }
        // Magic with an AI: its calls edit a hidden draft and leave the timeline alone; its edits,
        // played back in any order their dependencies allow, make exactly the draft.
        do {
            let m = EditorModel()
            var p = Project()
            p.assets = project.assets.filter { $0.kind == .video }
            m.load(p, url: nil)
            let before = m.project
            let draft = MCPDraft.open(m.project)
            defer { draft.close() }
            func call(_ name: String, _ args: [String: Any]) async -> (Any?, String?) {
                do {
                    let out = try await MCPTools.call(name, args, model: m, client: nil, draft: draft)
                    let text = out.first?["text"] as? String ?? ""
                    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), nil)
                } catch {
                    return (nil, (error as? MCPToolError)?.message ?? "\(error)")
                }
            }
            var good = false
            var detail = "no video with sound"
            if let asset = p.assets.first(where: { $0.hasAudio && $0.duration >= 4 }) {
                func added(_ r: Any?) -> String { ((r as? [String: Any])?["added"] as? [[String: Any]])?.first?["id"] as? String ?? "" }
                let a = added(await call("add_clip", ["asset_id": asset.id.uuidString, "duration": 3.0]).0)
                let b = added(await call("add_clip", ["asset_id": asset.id.uuidString, "source_start": 1.0, "duration": 2.0]).0)
                let c = added(await call("add_clip", ["asset_id": asset.id.uuidString, "source_start": 0.5, "duration": 1.5]).0)
                _ = await call("trim_clip", ["clip_id": a, "start": 0.5])
                _ = await call("set_grade", ["clip_ids": [b], "look": "Mono", "exposure": 0.2])
                _ = await call("add_title", ["text": "Hello", "start": 0.0, "duration": 1.5])
                _ = await call("set_transition", ["clip_id": b, "kind": "dissolve"])
                _ = await call("move_clip", ["clip_id": c, "start": 8.0])
                _ = await call("history", ["action": "undo"])   // takes back the move
                _ = await call("set_audio", ["clip_id": c, "gain_db": -12.0, "fade_out": 0.5])
                let (sped, speedError) = await call("set_speed", ["clip_id": b, "speed": 4.0])
                // Then a slow-motion moment in that sped-up clip (file 1–3): 25% from 1.5 to 2.2s, 400% around it.
                let (_, rampError) = await call("set_speed_ramp", ["clip_id": b, "speed": 0.25, "from": 1.5, "to": 2.2, "ease": 0.2, "around": 4.0])
                _ = await call("set_sequence", ["width": 1080, "height": 1920])
                _ = await call("delete_clips", ["clip_ids": [a], "ripple": true])
                // Two ripple deletes in a row: played as plain deletes side by side, then "Close gaps".
                _ = await call("delete_clips", ["clip_ids": [c], "ripple": true])
                let (_, refused) = await call("save_project", [:])
                let (_, frameError) = await call("get_frame", ["time": 1.0])
                let untouched = m.project == before
                let target = draft.project
                let plan = MCPDraft.plan(base: before, edits: draft.edits)
                // Played in order, and in shuffled orders that respect the dependencies.
                var orders: [[Int]] = [Array(plan.tasks.indices)]
                var rng = SeededRandom(seed: 7)
                for _ in 0..<20 {
                    var done = Set<Int>(), order: [Int] = []
                    while order.count < plan.tasks.count {
                        let ready = plan.tasks.indices.filter { !done.contains($0) && plan.tasks[$0].after.allSatisfy(done.contains) }
                        let pick = ready[Int(rng.next() * Double(ready.count)) % ready.count]
                        order.append(pick)
                        done.insert(pick)
                    }
                    orders.append(order)
                }
                // The order clips are listed in doesn't matter, only the clips.
                func same(_ x: Project, _ y: Project) -> Bool {
                    var x = x, y = y
                    x.clips.sort { $0.id.uuidString < $1.id.uuidString }
                    y.clips.sort { $0.id.uuidString < $1.id.uuidString }
                    return x == y
                }
                let failing = orders.indices.filter { k in
                    var q = before
                    for i in orders[k] { plan.tasks[i].edit.apply(&q, 1) }
                    if !same(q, target), k < 3 || CommandLine.arguments.contains("--verbose") {
                        let diff = q.clips.filter { c in target.clip(c.id) != c }.map { c in "\(c.kind.rawValue)@\(c.start)-\(c.end) vs \(target.clip(c.id).map { "\($0.start)-\($0.end)" } ?? "gone")" }
                        log("  order \(k) \(orders[k]) differs: \(diff) counts \(q.clips.count)/\(target.clips.count) after=\(plan.tasks.map(\.after)) labels=\(plan.tasks.map { $0.edit.label(1) })")
                    }
                    return !same(q, target)
                }
                let replayOK = failing.isEmpty
                let parallel = plan.tasks.filter { $0.after.isEmpty }.count
                let shapeOK = target.width == 1080 && target.clips.contains { $0.kind == .text && $0.text.string == "Hello" }
                    && target.clip(UUID(uuidString: c)!)?.start ?? 0 < 8 && target.clip(UUID(uuidString: a)!) == nil
                let ramped = target.clip(UUID(uuidString: b)!)
                let rampOK = rampError == nil && ramped?.isRamped == true && ramped?.speed == 0.25
                    && abs((ramped?.ramp?.inTo ?? 0) - 1.5) < 1e-3 && abs((ramped?.ramp?.outFrom ?? 0) - 2.2) < 1e-3
                    && abs((ramped.map { $0.speed(atSource: $0.sourceStart) } ?? 0) - 4) < 1e-6
                let speedOK = speedError == nil && sped != nil && rampOK
                good = untouched && replayOK && shapeOK && speedOK && refused != nil && frameError == nil && parallel > 1
                detail = "speed=\(speedOK) ramp=\(rampOK)\(rampError.map { " " + $0 } ?? "") untouched=\(untouched) replay=\(replayOK) failing=\(failing.count)/\(orders.count) shape=\(shapeOK) edits=\(plan.tasks.count) startFree=\(parallel) refused=\(refused != nil)"
            }
            log("MAGIC DRAFT \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // Connect buttons, against a throwaway home folder: Codex's settings keep every other line,
        // and the Claude extension holds a valid manifest and its launcher.
        do {
            let fm = FileManager.default
            let fake = outDir.appendingPathComponent("connect-home", isDirectory: true)
            try? fm.removeItem(at: fake)
            try? fm.createDirectory(at: fake.appendingPathComponent(".codex"), withIntermediateDirectories: true)
            let original = """
            model = "x"

            [mcp_servers.other]
            command = "other"

            [mcp_servers.editroom]
            command = "old"

            [mcp_servers.editroom.env]
            A = "1"

            [features]
            js_repl = false
            """
            let config = fake.appendingPathComponent(".codex/config.toml")
            try? original.write(to: config, atomically: true, encoding: .utf8)
            let c = AgentConnect.shared
            let realHome = c.home
            c.home = fake
            c.openInClaude = false
            defer { c.home = realHome; c.openInClaude = true }
            var good = true
            var detail = ""
            do {
                try c.connectCodex()
                let on = try String(contentsOf: config, encoding: .utf8)
                let sections = on.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
                let codexOK = c.codexConnected && on.contains("command = \"other\"") && on.contains("js_repl = false")
                    && !on.contains("\"old\"") && !on.contains("A = \"1\"")
                    && sections == ["[mcp_servers.other]", "[features]", "[mcp_servers.editroom]"]
                try c.disconnectCodex()
                let off = try String(contentsOf: config, encoding: .utf8)
                let offOK = !c.codexConnected && off.contains("[mcp_servers.other]") && off.contains("[features]")
                let backupOK = fm.fileExists(atPath: fake.appendingPathComponent(".codex/config.toml.before-editroom").path)

                let mcpb = try c.makeClaudeExtension()
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                let out = fake.appendingPathComponent("unzipped")
                unzip.arguments = ["-qo", mcpb.path, "-d", out.path]
                try unzip.run(); unzip.waitUntilExit()
                let manifest = (try? Data(contentsOf: out.appendingPathComponent("manifest.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let server = manifest["server"] as? [String: Any]
                let launcher = out.appendingPathComponent("server/editroom-mcp")
                let script = (try? String(contentsOf: launcher, encoding: .utf8)) ?? ""
                let claudeOK = manifest["name"] as? String == "editroom" && manifest["manifest_version"] as? String == "0.3"
                    && server?["type"] as? String == "binary" && (manifest["tools"] as? [Any])?.count == MCPTools.definitions.count
                    && script.contains("--mcp") && fm.isExecutableFile(atPath: launcher.path)
                    && fm.fileExists(atPath: out.appendingPathComponent("icon.png").path)
                // The launcher really reaches the server (which answers on this thread, so wait elsewhere).
                MCPServer.shared.start()
                try? await Task.sleep(nanoseconds: 300_000_000)
                let path = launcher.path
                let reply: String = await Task.detached {
                    let probe = Process()
                    probe.executableURL = URL(fileURLWithPath: "/bin/sh")
                    probe.arguments = [path]
                    let input = Pipe(), output = Pipe()
                    probe.standardInput = input
                    probe.standardOutput = output
                    do { try probe.run() } catch { return "" }
                    input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-ai"}}}"#.utf8 + [10]))
                    try? input.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    probe.waitUntilExit()
                    return String(data: data, encoding: .utf8) ?? ""
                }.value
                let launchOK = reply.contains("\"editroom\"")
                good = codexOK && offOK && backupOK && claudeOK && launchOK
                detail = "codex=\(codexOK) off=\(offOK) backup=\(backupOK) claude=\(claudeOK) launcher=\(launchOK)"
            } catch {
                good = false
                detail = error.localizedDescription
            }
            log("AGENT CONNECT \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // Downloading music for an agent: audio is kept (with its source noted), anything else refused.
        do {
            let folder = outDir.appendingPathComponent("download-test", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            let song = project.assets.first { $0.kind == .audio }?.url ?? project.assets.first { $0.kind == .video && $0.hasAudio }?.url
            let page = outDir.appendingPathComponent("page.html")
            try? "<html>not audio</html>".write(to: page, atomically: true, encoding: .utf8)
            var good = false
            var detail = "no audio to test with"
            if let song {
                let kept = try? await MediaDownload.fetch(song, name: "Test: Track/One", sourcePage: "https://example.com/track",
                                                          licence: "CC0, no attribution", into: folder, allowFiles: true)
                var refusedPage = false
                do { _ = try await MediaDownload.fetch(page, name: nil, sourcePage: nil, licence: nil, into: folder, allowFiles: true) }
                catch { refusedPage = true }
                var refusedHTTP = false
                do { _ = try await MediaDownload.fetch(URL(string: "http://example.com/a.mp3")!, name: nil, sourcePage: nil, licence: nil, into: folder) }
                catch { refusedHTTP = true }
                let notes = (try? String(contentsOf: folder.appendingPathComponent("Sources.txt"), encoding: .utf8)) ?? ""
                let keptOK = kept.map { FileManager.default.fileExists(atPath: $0.path) && $0.lastPathComponent.hasPrefix("Test  Track One") } ?? false
                let notesOK = notes.contains("CC0, no attribution") && notes.contains("https://example.com/track")
                let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("page") }
                good = keptOK && notesOK && refusedPage && refusedHTTP && leftovers.isEmpty
                detail = "kept=\(keptOK) notes=\(notesOK) refusedPage=\(refusedPage) refusedHTTP=\(refusedHTTP) leftovers=\(leftovers.count)"
            }
            log("DOWNLOAD \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // Deleting from the Media panel: picked items go (with Delete), and one Undo brings them back.
        do {
            let m = EditorModel()
            var p = Project()
            p.assets = project.assets
            m.load(p, url: nil)
            let ids = p.assets.prefix(2).map(\.id)
            m.mediaSelection = Set(ids)
            m.deleteSelected()
            let gone = ids.allSatisfy { id in m.project.asset(id) == nil } && m.mediaSelection.isEmpty
            m.undo()
            let back = ids.allSatisfy { id in m.project.asset(id) != nil } && m.project.assets.count == p.assets.count
            m.redo()
            let again = ids.allSatisfy { id in m.project.asset(id) == nil } && m.project.assets.count == p.assets.count - 2
            let good = ids.count == 2 && gone && back && again
            log("MEDIA DELETE \(good ? "OK" : "FAIL") gone=\(gone) undo=\(back) redo=\(again)")
            ok = ok && good
        }
        // Local Magic on an edit: repeats out, long shots trimmed, cuts on the beat, ends on a bar, no gaps,
        // the song trimmed to fit, and a doubled title out.
        do {
            func video(_ name: String) -> MediaAsset {
                MediaAsset(path: "/tmp/\(name).mov", name: name, kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false)
            }
            let a = video("A"), b = video("B")
            let songAsset = MediaAsset(path: "/tmp/song.m4a", name: "Song", kind: .audio, duration: 60, width: 0, height: 0, fps: 0, hasAudio: true)
            var p = Project()
            p.assets = [a, b, songAsset]
            while p.videoTracks.count < 2 { p.videoTracks.append(Track(kind: .video)) }
            let v1 = p.videoTracks[0].id, v2 = p.videoTracks[1].id, a1 = p.audioTracks[0].id
            func shot(_ asset: MediaAsset, _ start: Double, _ length: Double, src: Double) -> Clip {
                var c = Clip(trackID: v1, kind: .video, assetID: asset.id, start: start, duration: length)
                c.sourceStart = src
                return c
            }
            p.clips = [shot(a, 0, 5, src: 0), shot(b, 5, 5, src: 0), shot(a, 10, 5, src: 0.5), shot(b, 15, 2, src: 6)]
            p.clips.append(Clip(trackID: a1, kind: .audio, assetID: songAsset.id, start: 0, duration: 30))
            var t1 = Clip(trackID: v2, kind: .text, start: 0, duration: 2); t1.text.string = "Hi"
            p.addTrack(.video)
            var t2 = Clip(trackID: p.videoTracks[2].id, kind: .text, start: 0, duration: 2); t2.text.string = "Hi"
            p.clips += [t1, t2]
            // Sharp in the middle of each file, soft at the ends.
            func analysis() -> ClipAnalysis {
                ClipAnalysis(duration: 10, created: nil, samples: stride(from: 0.0, through: 10, by: 0.25).map { t in
                    ClipAnalysis.Sample(time: t, luma: 0.45, sharpness: 400 - 30 * abs(t - 5) * abs(t - 5), motion: 0.01, color: 0.3, faces: 0)
                })
            }
            let music = MusicAnalysis(duration: 60, bpm: 120, beats: stride(from: 0.0, to: 60, by: 0.5).map { $0 }, barPhase: 0,
                                      energy: Array(repeating: 0.5, count: 120))
            var good = false
            var detail = "no plan"
            if let outcome = LocalImprover.plan(project: p, analyses: [a.id: analysis(), b.id: analysis()], music: music) {
                var q = p
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let kept = q.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
                let gapless = zip(kept, kept.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-6 } && abs((kept.first?.start ?? 1)) < 1e-6
                let onBeats = kept.allSatisfy { abs(($0.end * 2).rounded() - $0.end * 2) < 1e-6 }
                let end = kept.last?.end ?? 0
                let onBar = abs((end / 2).rounded() - end / 2) < 1e-6
                let repeatsOut = kept.filter { $0.assetID == a.id }.count == 1
                let trimmed = kept.allSatisfy { $0.duration <= 4.5 + 1e-6 }
                let song = q.clips.first { $0.assetID == songAsset.id }
                let songFits = song.map { abs($0.end - end) < 1e-6 && $0.fadeOut > 0 } ?? false
                let titleOnce = q.clips.filter { $0.kind == .text }.count == 1
                good = gapless && onBeats && onBar && repeatsOut && trimmed && songFits && titleOnce
                detail = "\(outcome.summary) | gapless=\(gapless) beats=\(onBeats) bar=\(onBar) repeats=\(repeatsOut) trimmed=\(trimmed) song=\(songFits) title=\(titleOnce) cuts=\(kept.map { $0.end })"
            }
            // And following a recipe: 4 seconds, fast, Mono, no music, vertical.
            var recipe = LocalRecipe()
            recipe.seconds = 4
            recipe.pace = .fast
            recipe.look = "Mono"
            recipe.music = .off
            recipe.frame = .vertical
            if let outcome = LocalImprover.plan(project: p, analyses: [a.id: analysis(), b.id: analysis()], music: nil, recipe: recipe) {
                var q = p
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let kept = q.clips.filter { $0.trackID == v1 }
                let length = (kept.map(\.end).max() ?? 0) - (kept.map(\.start).min() ?? 0)
                let recipeOK = length <= 4.05 && length >= 2 && kept.allSatisfy { $0.grade?.look == "Mono" }
                    && q.width == 1080 && q.height == 1920 && !q.clips.contains { $0.assetID == songAsset.id }
                good = good && recipeOK
                detail += " | recipe=\(recipeOK) length=\(length) \(outcome.summary)"
            } else {
                good = false
                detail += " | recipe: no plan"
            }
            // Longer than the edit is now (after repeats come out): shots grow into their files, with no
            // gaps or overlaps, cuts on the beat, ending near the length asked for.
            var longer = LocalRecipe()
            longer.seconds = 25
            if let outcome = LocalImprover.plan(project: p, analyses: [a.id: analysis(), b.id: analysis()], music: music, recipe: longer) {
                var q = p
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let kept = q.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
                let end = kept.last?.end ?? 0
                let gapless = zip(kept, kept.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-6 }
                let inFiles = kept.allSatisfy { $0.sourceStart >= -1e-6 && $0.sourceStart + $0.duration * $0.speed <= 10 + 1e-6 }
                let longOK = kept.count == 3 && gapless && inFiles && abs(end - 25) <= 2 && outcome.notes.isEmpty
                good = good && longOK
                detail += " | longer=\(longOK) end=\(end) \(outcome.summary)"
            } else {
                good = false
                detail += " | longer: no plan"
            }
            // Named media: "i only want img_1607 video. nothing else on timeline" keeps just that file's shots
            // (both copies: nothing else unasked), closes the gaps, and clears titles and music.
            let lib = [MediaAsset(path: "/tmp/IMG_1607.MOV", name: "IMG_1607", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false),
                       MediaAsset(path: "/tmp/IMG_1818.MOV", name: "IMG_1818", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false)]
            let ask = "i only want img_1607 video. nothing else on timeline"
            let found = LocalBrain.named(in: ask, media: lib)
            var onlyA = LocalRecipe()
            LocalBrain.applyMedia(&onlyA, named: [a], action: "unchanged", request: ask)
            let readOK = found.map(\.name) == ["IMG_1607"] && LocalBrain.named(in: "take out 1818", media: lib).map(\.name) == ["IMG_1818"]
                && onlyA.keepOnly == [a.id] && onlyA.clearRest
            if let outcome = LocalImprover.plan(project: p, analyses: [a.id: analysis(), b.id: analysis()], music: music, recipe: onlyA) {
                var q = p
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let kept = q.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start }
                let onlyOK = readOK && kept.count == 2 && kept.allSatisfy { $0.assetID == a.id } && abs(kept[0].start) < 1e-6
                    && abs(kept[0].end - kept[1].start) < 1e-6 && abs(kept[1].duration - 5) < 1e-6
                    && !q.clips.contains { $0.kind == .text } && !q.clips.contains { $0.assetID == songAsset.id }
                good = good && onlyOK
                detail += " | only=\(onlyOK) read=\(readOK) \(outcome.summary)"
            } else {
                good = false
                detail += " | only: no plan (read=\(readOK))"
            }
            // Sound effects: a whoosh from the library leads into every cut, on a track of its own.
            var withFX = p
            let whoosh = MediaAsset(path: "/tmp/Whoosh 1.wav", name: "Whoosh 1", kind: .audio, duration: 1, width: 0, height: 0, fps: 0, hasAudio: true)
            withFX.assets.append(whoosh)
            var fx = LocalRecipe()
            fx.soundEffects = true
            fx.onlyAsked = true
            if let outcome = LocalImprover.plan(project: withFX, analyses: [a.id: analysis(), b.id: analysis()], music: music, recipe: fx) {
                var q = withFX
                for task in outcome.plan.tasks { task.edit.apply(&q, 1) }
                let placed = q.clips.filter { $0.assetID == whoosh.id }.sorted { $0.start < $1.start }
                let cutsNow = q.clips.filter { $0.trackID == v1 }.map(\.end).sorted().dropLast()
                let leadIn = placed.count == cutsNow.count && zip(placed, cutsNow).allSatisfy { $0.start < $1 && $0.end > $1 - 1e-6 }
                let ownTrack = Set(placed.map(\.trackID)).count == 1 && !q.clips.contains { c in placed.first.map { c.trackID == $0.trackID && c.assetID != whoosh.id } ?? false }
                let fxOK = !placed.isEmpty && leadIn && ownTrack
                good = good && fxOK
                detail += " | sfx=\(fxOK) placed=\(placed.count) \(outcome.summary)"
            } else {
                good = false
                detail += " | sfx: no plan"
            }
            // The request check: settings the request doesn't mention are dropped (the on-device model over-fills).
            var noisy = LocalRecipe()
            noisy.seconds = 20; noisy.pace = .calm; noisy.look = "none"; noisy.music = .off; noisy.frame = .square
            noisy.cannotDo = "find new music, sound effects"
            let checked = LocalBrain.checked(noisy, against: "add sound effects and make it 20 seconds")
            let checkOK = checked.seconds == 20 && checked.pace == .unchanged && checked.look == nil && checked.music == .unchanged
                && checked.frame == .unchanged && checked.cannotDo == "sound effects"
            // A question with numbers in it isn't a length; real lengths in other wordings still are.
            var asked = LocalRecipe(); asked.seconds = 100
            let lengths = LocalBrain.checked(asked, against: "what's 5+5?").seconds == nil
                && LocalBrain.checked(asked, against: "make it 30s").seconds == 100
                && LocalBrain.checked(asked, against: "1:30 long cut").seconds == 100
                && LocalBrain.checked(asked, against: "length of 45").seconds == 100
            good = good && checkOK && lengths
            detail += " | check=\(checkOK) lengths=\(lengths)"
            // @ mentions: found by name (with or without the extension, any case), not inside an address;
            // in plain words for Apple's model; Local's direct edits on what they point at.
            do {
                let file = MediaAsset(path: "/tmp/IMG_1607.MOV", name: "IMG_1607.MOV", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false)
                let lib = [file, MediaAsset(path: "/tmp/Beach day.mov", name: "Beach day.mov", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: false)]
                let text = "Tighten @Selected, open on @img_1607 then @in-out and @Beach day.mov. me@x.com @nothing @playheads"
                let found = MagicMention.find(in: text, media: lib).map(\.mention)
                let findOK = found == [.selected, .media(file.id), .range, .media(lib[1].id)]
                    && MagicMention.find(in: "open on @media:img_1607 now", media: lib).map(\.mention) == [.media(file.id)]
                    && MagicMention.find(in: "open on @media:img_1607 now", media: lib).first?.range == NSRange(location: 8, length: 15)
                let plainOK = MagicMention.plain("cut @selected at @playhead with @IMG_1607", media: lib)
                    == "cut the selected clips at the playhead with IMG_1607.MOV"
                let first = p.clips.filter { $0.trackID == v1 }.min { $0.start < $1.start }!
                let ptr = MagicPointers(playhead: 7, selected: [first.id], range: (2, 4))
                func run(_ ask: String, _ r: LocalRecipe = LocalRecipe()) -> Project? {
                    guard let o = LocalPointed.plan(request: ask, recipe: r, pointers: ptr, project: p), let plan = o.plan else { return nil }
                    var q = plan.base
                    for task in plan.tasks { task.edit.apply(&q, 1) }
                    return q
                }
                let shots = { (q: Project) in q.clips.filter { $0.trackID == v1 }.sorted { $0.start < $1.start } }
                let removed = run("@selected is no good").map(shots) ?? []
                let removeOK = removed.count == 3 && !removed.contains { $0.id == first.id } && abs(removed[0].start) < 1e-6
                let ended = run("end it at @playhead").map(\.duration) ?? 0
                let endOK = abs(ended - 7) < 1e-6
                let cut = run("remove @in-out").map(shots) ?? []
                let rangeOK = cut.count == 5 && abs((cut.last?.end ?? 0) - 15) < 1e-6
                var mono = LocalRecipe(); mono.look = "Mono"
                let looked = run("make @selected black and white", mono)
                let lookOK = looked?.clips.first { $0.id == first.id }?.grade?.look == "Mono"
                    && looked?.clips.filter { $0.id != first.id && $0.grade?.look == "Mono" }.isEmpty == true
                let wholeOK = LocalPointed.plan(request: "make it shorter", recipe: LocalRecipe(), pointers: ptr, project: p) == nil
                let brief = MagicAgent.brief(request: "@selected is weak", project: p, pointers: ptr)
                let briefOK = brief.contains("@selected means exactly the selected clips") && brief.contains("Playhead: 7.00s")
                // Moving shots by name, and naming files on an edit never takes the others out.
                func order(_ ask: String) -> [UUID] {
                    guard let o = LocalPointed.plan(request: ask, recipe: LocalRecipe(), pointers: ptr, project: p), let plan = o.plan else { return [] }
                    var q = plan.base
                    for task in plan.tasks { task.edit.apply(&q, 1) }
                    return shots(q).compactMap(\.assetID)
                }
                let moveOK = order("put @B in front of @A") == [b.id, a.id, a.id, b.id]
                    && order("swap @A and @B") == [b.id, a.id, a.id, b.id]
                    && order("move @A to the end") == [b.id, a.id, b.id, a.id]
                var named = LocalRecipe()
                LocalBrain.applyMedia(&named, named: [a, b], action: "only", request: "put @B in front of @A", pointed: [a.id, b.id], hasEdit: true)
                let keepOK = named.keepOnly.isEmpty && named.takeOut.isEmpty
                // @clip: one clip in particular: named by file (·2 for the second use) or a title's words.
                let labels = MagicMention.clipLabels(p).map(\.name)
                let secondA = p.clips.filter { $0.assetID == a.id }.sorted { $0.start < $1.start }[1]
                let clipFind = MagicMention.find(in: "fix @clip:A·2 and @clip:Hi", media: p.assets, clips: MagicMention.clipLabels(p)).map(\.mention)
                let afterRemove = run("@clip:A·2 is no good").map(shots) ?? []
                let clipOK = labels.prefix(3) == ["Hi", "Hi·2", "A"] && labels.contains("A·2") && labels.contains("B·2")
                    && clipFind.first == .clip(secondA.id) && clipFind.count == 2
                    && afterRemove.count == 3 && !afterRemove.contains { $0.id == secondA.id } && afterRemove.contains { $0.id == first.id }
                    && order("put @clip:B·2 in front of @clip:A") == [b.id, a.id, b.id, a.id]
                // Typed times: the viewer's timecode (frames at the project's rate), m:ss, h:mm:ss; a span is a range.
                func near(_ x: Double?, _ y: Double) -> Bool { x.map { abs($0 - y) < 1e-6 } ?? false }
                let tc = MagicTimes.span(in: "between 00:00:05:15 and 00:00:06:00 find a better clip", fps: 30)
                let timeOK = near(tc?.start, 5.5) && near(tc?.end, 6)
                    && near(MagicTimes.span(in: "from 5s to 6.5 seconds", fps: 30)?.end, 6.5)
                    && near(MagicTimes.span(in: "cut 0:05 to 0:06", fps: 30)?.start, 5)
                    && MagicTimes.span(in: "make it 0:30 long", fps: 30) == nil
                    && MagicTimes.span(in: "make it 30s, fast", fps: 30) == nil
                    && near(MagicTimes.times(in: "at 1:02:30", fps: 30).first?.seconds, 3750)
                    && MagicTimes.times(in: "make it 0:30", fps: 30).map(\.seconds) == [30]
                let typedCut = run("remove between 0:02 and 0:04").map(shots) ?? []
                let typedOK = typedCut.count == 5 && abs((typedCut.last?.end ?? 0) - 15) < 1e-6
                    && MagicAgent.brief(request: "between 0:05 and 0:06 find a better clip", project: p, pointers: ptr).contains("is 5.00s to 6.00s on the timeline")
                // Speech: sentences, pauses and phrases from a transcript; Local cuts the pauses out of the
                // talking shots, the shot's own sound with it, and leaves the rest in sync.
                let said = Transcript(words: [.init(start: 1, end: 1.4, text: "Welcome"), .init(start: 1.4, end: 2, text: "back."),
                                              .init(start: 5, end: 5.5, text: "It's"), .init(start: 5.5, end: 6, text: "raining.")], language: "en_US")
                let speechOK = said.speech().count == 2 && said.sentences().map(\.text) == ["Welcome back.", "It's raining."]
                    && said.says("it's RAINING") && !said.says("raining it's")
                    && said.snippet("rai", typing: true).map { $0.match == "raining." && $0.before == "Welcome back. It's" } == true
                    && said.says("it's rai", typing: true) && !said.says("it's rai") && !said.says("welc raining", typing: true)
                var sp = Project()
                let talk = MediaAsset(path: "/tmp/talk.mov", name: "talk", kind: .video, duration: 10, width: 1920, height: 1080, fps: 30, hasAudio: true)
                sp.assets = [talk]
                let sv1 = sp.videoTracks[0].id, sa1 = sp.audioTracks[0].id, link = UUID()
                var tv = Clip(trackID: sv1, kind: .video, assetID: talk.id, start: 0, duration: 10); tv.linkID = link
                var ta = Clip(trackID: sa1, kind: .audio, assetID: talk.id, start: 0, duration: 10); ta.linkID = link
                var broll = Clip(trackID: sv1, kind: .video, assetID: a.id, start: 10, duration: 3); broll.linkID = UUID()
                sp.clips = [tv, ta, broll]
                let cutPlan = LocalSpeech.plan(project: sp, only: nil) { $0 == talk.id ? said : Transcript(words: [], language: "") }
                var sq = cutPlan.plan?.base ?? sp
                for task in cutPlan.plan?.tasks ?? [] { task.edit.apply(&sq, 1) }
                let vids = sq.clips.filter { $0.trackID == sv1 }.sorted { $0.start < $1.start }
                let auds = sq.clips.filter { $0.trackID == sa1 }.sorted { $0.start < $1.start }
                // Kept: 0.88-2.2 and 4.88-6.2 of the talk (1.32s each), then the 3s b-roll untouched.
                let cutOK = vids.count == 3 && abs(vids[0].start) < 1e-6 && abs(vids[0].duration - 1.32) < 1e-6
                    && abs(vids[1].sourceStart - 4.88) < 1e-6 && abs(vids[2].start - 2.64) < 1e-6 && vids[2].assetID == a.id
                    && auds.count == 2 && zip(auds, vids).allSatisfy { abs($0.start - $1.start) < 1e-6 && abs($0.duration - $1.duration) < 1e-6 }
                    && LocalSpeech.asks("cut out all the dead space") && !LocalSpeech.asks("make it fast")
                // Scene tags: a word matches a tag (plural or not), and as it's typed.
                let tags = SceneTags(tags: [.init(name: "swimming pool", confidence: 0.8, times: [1]), .init(name: "chair", confidence: 0.6, times: [2])])
                let tagOK = tags.shows("pool") && tags.shows("chairs") && tags.shows("po", typing: true) && !tags.shows("po") && !tags.shows("beach")
                    && SceneTags(tags: [.init(name: "portal", confidence: 0.7, times: [])]).shows("door")
                    && SceneTags(tags: [.init(name: "adult", confidence: 0.7, times: [])]).shows("wom", typing: true)
                // Local's ramps: a slow-mo moment at the playhead in the talk shot; then ramps into the cut.
                let at5 = MagicPointers(playhead: 5, selected: [], range: nil)
                var rq = sp
                let moment = LocalRamp.plan(request: "speed ramp here", pointers: at5, project: sp)
                for task in moment.plan?.tasks ?? [] { task.edit.apply(&rq, 1) }
                let rt = rq.clip(tv.id)
                var cq = sp
                let cutsPlan = LocalRamp.plan(request: "ramp into the cuts", pointers: at5, project: sp)
                for task in cutsPlan.plan?.tasks ?? [] { task.edit.apply(&cq, 1) }
                let before = cq.clip(tv.id), after = cq.clip(broll.id)
                let rampOK = LocalRamp.asks("add a speed ramp") && LocalRamp.asks("slow-mo moment please") && !LocalRamp.asks("make it slow motion")
                    && rt?.isRamped == true && abs((rt?.speed ?? 0) - 0.3) < 1e-9 && rq.clip(ta.id)?.isRamped == true
                    && abs((rt.map { $0.speed(atSource: $0.sourceStart + 5) } ?? 0) - 0.3) < 1e-6
                    && abs((before.map { $0.speed(atSource: $0.sourceStart + $0.sourceLength - 1e-3) } ?? 0) - 4) < 0.05
                    && abs((after.map { $0.speed(atSource: $0.sourceStart) } ?? 0) - 4) < 1e-6
                    && abs((after.map { $0.speed(atSource: $0.sourceStart + $0.sourceLength * 0.5) } ?? 0) - 1) < 1e-6
                // Every clip in a short montage: 20 clips in 10s at 120 bpm (a beat is 0.5s) needs half-beat cuts.
                let many = (0..<20).map { i in
                    (MediaAsset(path: "/tmp/m\(i).mov", name: "m\(i)", kind: .video, duration: 6, width: 1920, height: 1080, fps: 30, hasAudio: false),
                     ClipAnalysis(duration: 6, created: Date(timeIntervalSince1970: Double(i) * 100),
                                  samples: (0..<12).map { k in .init(time: Double(k) * 0.5, luma: 0.4 + Double(i % 3) * 0.1, sharpness: 50 + Double(k), motion: 0.01 * Double(k % 4), color: 0.3, faces: 0) }))
                }
                let song = MediaAsset(path: "/tmp/song.m4a", name: "song", kind: .audio, duration: 60, width: 0, height: 0, fps: 0, hasAudio: true)
                let beat = MusicAnalysis(duration: 60, bpm: 120, beats: (0..<120).map { Double($0) * 0.5 }, barPhase: 0, energy: Array(repeating: 0.5, count: 120))
                var everyRecipe = LocalRecipe()
                everyRecipe.seconds = 10
                everyRecipe.pace = .fast
                everyRecipe.every = true
                everyRecipe.wholeLibrary = true
                let montage = AutoPlanner.decide(project: Project(), clips: many, music: (song, beat), recipe: everyRecipe)
                let montageLength = montage.map { $0.shots.reduce(0) { $0 + $1.duration } } ?? 0
                let everyOK = LocalBrain.wantsEvery("fit all the videos within 10s") && LocalBrain.wantsEvery("use every clip")
                    && LocalBrain.wantsEvery("all of my clips") && !LocalBrain.wantsEvery("make it 10 seconds")
                    && Set(montage?.shots.map(\.asset.id) ?? []).count == 20 && montageLength <= 10.2 && montageLength > 8
                let countOK = everyOK && LocalBrain.shotCount("create 7 second montage with at least 10 clips") == 10
                    && LocalBrain.shotCount("twelve quick cuts") == 12 && LocalBrain.shotCount("make it 7 seconds") == nil
                let mOK = rampOK && countOK && tagOK && speechOK && cutOK && timeOK && typedOK && clipOK && moveOK && keepOK && findOK && plainOK && removeOK && endOK && rangeOK && lookOK && wholeOK && briefOK
                log("MENTIONS \(mOK ? "OK" : "FAIL") every=\(everyOK) (\(Set(montage?.shots.map(\.asset.id) ?? []).count) clips, \(String(format: "%.1f", montageLength))s) ramp=\(rampOK) \(moment.said) / \(cutsPlan.said) count=\(countOK) tags=\(tagOK) speech=\(speechOK) cut=\(cutOK) \(cutPlan.said) time=\(timeOK) typed=\(typedOK) clip=\(clipOK) \(labels) move=\(moveOK) keep=\(keepOK) find=\(findOK) plain=\(plainOK) remove=\(removeOK) end=\(endOK) range=\(rangeOK) look=\(lookOK) whole=\(wholeOK) brief=\(briefOK)")
                good = good && mOK
            }
            log("LOCAL IMPROVE \(good ? "OK" : "FAIL") \(detail)")
            ok = ok && good
        }
        // Shortcuts: key presses find their action; changing one takes it from whatever had it; resetting
        // brings the defaults back. The person's own shortcuts are put back afterwards.
        do {
            let saved = UserDefaults.standard.data(forKey: "shortcuts")
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: "shortcuts") } else { UserDefaults.standard.removeObject(forKey: "shortcuts") }
            }
            UserDefaults.standard.removeObject(forKey: "shortcuts")
            let keys = ShortcutStore()
            func press(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> KeyCombo? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code).flatMap(KeyCombo.init(event:))
            }
            let space = press(" ", code: 49).flatMap(keys.action(for:))
            let scrub = press("S", code: 1, .shift).flatMap(keys.action(for:))
            let save = press("s", code: 1, .command).flatMap(keys.action(for:))
            let ripple = press("\u{7f}", code: 51, .shift).flatMap(keys.action(for:))
            let findOK = space == .playPause && scrub == .audioScrubbing && save == .save && ripple == .rippleDelete
            // P for Snapping; then S (Snapping's old key) for Loop, which has to take it from nobody.
            keys.set(.snapping, to: KeyCombo("p"))
            let taken = keys.set(.loop, to: KeyCombo("s"))
            let moved = keys.action(for: KeyCombo("p")) == .snapping && keys.action(for: KeyCombo("s")) == .loop && taken == nil
            // ⇧S for Loop takes it from Audio Scrubbing.
            let stolen = keys.set(.loop, to: KeyCombo("s", shift: true))
            let stealOK = stolen == .audioScrubbing && keys.combos(.audioScrubbing).isEmpty
            let reloaded = ShortcutStore()
            let persisted = reloaded.combos(.snapping) == [KeyCombo("p")]
            reloaded.resetAll()
            let resetOK = ShortcutStore().combos(.snapping) == ShortcutAction.snapping.defaults
            // Menus never get plain Delete (it would delete clips from Settings or a sheet).
            let menuOK = reloaded.menu(.delete) == nil && reloaded.menu(.save) != nil
            let good = findOK && moved && stealOK && persisted && resetOK && menuOK
            log("SHORTCUTS \(good ? "OK" : "FAIL") find=\(findOK) move=\(moved) steal=\(stealOK) saved=\(persisted) reset=\(resetOK) menu=\(menuOK)")
            ok = ok && good
        }
        log(ok ? "SELFTEST OK" : "SELFTEST FAIL")
    }
}
