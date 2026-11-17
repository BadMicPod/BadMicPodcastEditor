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
        text.fadeOutCurve = .smooth
        // Grade the sped-up section: mono look plus a strong warm push in the highlights.
        var grade = ColorGrade()
        grade.look = "Mono"
        grade.highlights = WheelPoint(x: 1, y: 0)
        c2.grade = grade
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
        log(ok ? "SELFTEST OK" : "SELFTEST FAIL")
    }
}
