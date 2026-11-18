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
                    built = shots.count == d.shots.count && gapless && shots.allSatisfy { $0.grade?.look == d.look }
                        && p.clips.contains { $0.kind == .text && $0.text.string == d.title }
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
        log(ok ? "SELFTEST OK" : "SELFTEST FAIL")
    }
}
