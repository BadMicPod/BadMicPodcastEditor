import AppKit
import Combine
import SwiftUI

struct TimelineCanvasView: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> TimelineCanvas { TimelineCanvas(model: model) }
    func updateNSView(_ nsView: TimelineCanvas, context: Context) {}
}

/// The playhead lives in its own layer-backed view so moving it never redraws the clips.
final class PlayheadView: NSView {
    static let width: CGFloat = 16

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let mid = bounds.midX
        let l = mid - 5.5, r = mid + 5.5
        let top: CGFloat = 5, shoulder: CGFloat = 13, tip: CGFloat = 19, rad: CGFloat = 3
        // One closed shape: rounded cap narrowing to a point, with the stem running straight out of the tip.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: l, y: top + rad))
        p.addArc(tangent1End: CGPoint(x: l, y: top), tangent2End: CGPoint(x: l + rad, y: top), radius: rad)
        p.addLine(to: CGPoint(x: r - rad, y: top))
        p.addArc(tangent1End: CGPoint(x: r, y: top), tangent2End: CGPoint(x: r, y: top + rad), radius: rad)
        p.addLine(to: CGPoint(x: r, y: shoulder))
        p.addLine(to: CGPoint(x: mid + 0.5, y: tip))
        p.addLine(to: CGPoint(x: mid + 0.5, y: bounds.height))
        p.addLine(to: CGPoint(x: mid - 0.5, y: bounds.height))
        p.addLine(to: CGPoint(x: mid - 0.5, y: tip))
        p.addLine(to: CGPoint(x: l, y: shoulder))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(Theme.NS.accent.cgColor)
        ctx.fillPath()
    }
}

final class TimelineCanvas: NSView {
    private let model: EditorModel
    private var view: TimelineViewState { model.view }
    private var bag = Set<AnyCancellable>()
    private let playheadView = PlayheadView()
    private var layout = TimelineLayout(project: Project(), rowHeight: 62)

    // MARK: Interaction state

    private enum Zone { case body, left, right, fadeIn, fadeOut, gain }

    private struct Hit {
        let clip: Clip
        let zone: Zone
        let rect: CGRect
    }

    private enum Lane {
        case track(Track, Int)
        case newVideo
        case newAudio
        case none
    }

    private enum Drag {
        case none
        case scrub
        case pendingMove(grabbed: Clip, point: CGPoint, time: Double)
        case move(grabbed: Clip, time: Double, originals: [Clip])
        case trim(grabbed: Clip, left: Bool, time: Double, originals: [Clip])
        case fade(id: UUID, fadeIn: Bool)
        case gain(id: UUID, startY: CGFloat, startNorm: CGFloat, height: CGFloat)
        case marquee(origin: CGPoint, base: Set<UUID>)
    }

    private var drag = Drag.none
    private var overrides: [UUID: Clip] = [:]
    private var ghosts: [Clip] = []
    private var hover: (id: UUID, zone: Zone)?
    /// Where the current drag has snapped to. Landing on a new edge gives a light tap on the trackpad.
    private var snapLine: Double? {
        didSet {
            if let s = snapLine, s != oldValue { Self.tap() }
        }
    }
    /// While dragging the playhead, the time shown beside it on the ruler.
    private var scrubReadout: Double?
    private var lastScrubSnap: Double?

    private static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    private var cutHover: (id: UUID, time: Double)?
    private var marquee: CGRect?
    private var bubble: (text: String, point: CGPoint)?
    private var moveTrackDelta = 0
    private var dropInfo: (video: UUID, audio: UUID, start: Double)?
    private var cursor = NSCursor.arrow
    private var lastDragPoint = CGPoint.zero
    private var autoscrollTimer: Timer?
    private var autoscrollVelocity: CGFloat = 0

    // MARK: Setup

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        playheadView.wantsLayer = true
        playheadView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(playheadView)
        registerForDraggedTypes([.fileURL, .string])

        model.objectWillChange.sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        model.view.objectWillChange.sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        model.media.onVisualUpdate = { [weak self] in self?.needsDisplay = true }
        model.tickHandlers.append { [weak self] in self?.tick() }

        // The track headers sit beside this view; scrolling over them should scroll the timeline too.
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window else { return event }
                let frame = self.convert(self.bounds, to: nil)
                let headers = CGRect(x: frame.minX - TimelineLayout.headerWidth - 1, y: frame.minY,
                                     width: TimelineLayout.headerWidth + 1, height: frame.height)
                guard headers.contains(event.locationInWindow) else { return event }
                if event.type == .magnify { self.magnify(with: event) } else { self.scrollWheel(with: event) }
                return nil
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let state = view
        DispatchQueue.main.async {
            if state.viewWidth != newSize.width { state.viewWidth = newSize.width }
            if state.viewHeight != newSize.height { state.viewHeight = newSize.height }
            if state.needsInitialCentering, newSize.height > 0 {
                state.needsInitialCentering = false
                self.model.centerRows()
            }
            self.model.clampView()
        }
        playheadView.frame.size = CGSize(width: PlayheadView.width, height: newSize.height)
        playheadView.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep keyboard focus on the timeline rather than the first text field SwiftUI finds.
        for delay in [0.0, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let window = self.window, !(window.firstResponder is NSText) || delay > 0 else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    // MARK: Geometry

    private var pps: CGFloat { view.pps }

    private func x(_ time: Double) -> CGFloat { CGFloat(time) * pps - view.scrollX }
    private func time(atX x: CGFloat) -> Double { Double((x + view.scrollX) / pps) }

    private func rect(for c: Clip) -> CGRect? {
        guard let band = layout.band(for: c.trackID) else { return nil }
        return CGRect(x: x(c.start), y: TimelineLayout.ruler + band.y - view.scrollY,
                      width: max(CGFloat(c.duration) * pps, 1), height: band.height)
    }

    private func lane(atY y: CGFloat) -> Lane {
        let cy = y - TimelineLayout.ruler + view.scrollY
        if cy < layout.videoZoneY + TimelineLayout.zone { return .newVideo }
        if cy >= layout.audioZoneY { return .newAudio }
        for row in layout.rows where cy >= row.y && cy < row.y + row.height + TimelineLayout.gap {
            return .track(row.track, row.index)
        }
        return .none
    }

    private func setScroll(x: CGFloat, y: CGFloat) {
        model.setView(scrollX: x, scrollY: y)
    }

    private func tick() {
        var px = x(model.playhead)
        if model.isPlaying, px > bounds.width - 28 || px < 0 {
            model.setView(scrollX: CGFloat(model.playhead) * pps - 48)
            px = x(model.playhead)
        }
        let origin = CGPoint(x: ((px - PlayheadView.width / 2) * 2).rounded() / 2, y: 0)
        let hidden = px < -PlayheadView.width || px > bounds.width + PlayheadView.width
        if playheadView.isHidden != hidden { playheadView.isHidden = hidden }
        if playheadView.frame.origin != origin {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playheadView.setFrameOrigin(origin)
            CATransaction.commit()
        }
    }

    // MARK: Snapping

    private var snappingActive: Bool {
        model.snapping != NSEvent.modifierFlags.contains(.command)
    }

    private func snap(_ candidates: [Double], to targets: [Double], pixels: CGFloat = 8) -> (delta: Double, target: Double)? {
        guard snappingActive else { return nil }
        let threshold = Double(pixels / pps)
        var best: (delta: Double, target: Double)?
        for c in candidates {
            for t in targets {
                let d = t - c
                if abs(d) <= threshold, best == nil || abs(d) < abs(best!.delta) { best = (d, t) }
            }
        }
        return best
    }

    // MARK: Hit testing

    private func fadeHandleX(_ c: Clip, _ r: CGRect, fadeIn: Bool) -> CGFloat {
        let raw = fadeIn ? r.minX + CGFloat(c.fadeIn) * pps : r.maxX - CGFloat(c.fadeOut) * pps
        return min(max(raw, r.minX + 6), r.maxX - 6)
    }

    private static func gainNorm(_ db: Double) -> CGFloat {
        db >= 0 ? 0.3 - CGFloat(db / 12) * 0.2 : 0.3 + CGFloat(-db / 60) * 0.62
    }

    private static func gainDB(norm: CGFloat) -> Double {
        let n = min(max(norm, 0.1), 0.92)
        let db = n <= 0.3 ? Double((0.3 - n) / 0.2) * 12 : -Double((n - 0.3) / 0.62) * 60
        return (db * 10).rounded() / 10
    }

    private func hit(at p: CGPoint) -> Hit? {
        guard p.y >= TimelineLayout.ruler else { return nil }
        for c in model.project.clips where !model.project.isLocked(c.trackID) {
            guard let r = rect(for: c), r.contains(p) else { continue }
            let showHandles = r.width > 36
            if showHandles, p.y < r.minY + 17 {
                let di = abs(p.x - fadeHandleX(c, r, fadeIn: true))
                let dout = abs(p.x - fadeHandleX(c, r, fadeIn: false))
                if min(di, dout) <= 7 { return Hit(clip: c, zone: di <= dout ? .fadeIn : .fadeOut, rect: r) }
            }
            let edge = min(7, max(2, r.width / 4))
            if p.x - r.minX <= edge { return Hit(clip: c, zone: .left, rect: r) }
            if r.maxX - p.x <= edge { return Hit(clip: c, zone: .right, rect: r) }
            if c.kind == .audio, abs(p.y - (r.minY + Self.gainNorm(c.gainDB) * r.height)) <= 3.5 {
                return Hit(clip: c, zone: .gain, rect: r)
            }
            return Hit(clip: c, zone: .body, rect: r)
        }
        return nil
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p)
        if model.skimming, !model.isPlaying {
            model.skim(to: time(atX: p.x))
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if model.skimTime != nil {
            model.skim(to: nil)
            needsDisplay = true
        }
        if hover != nil || cutHover != nil {
            hover = nil
            cutHover = nil
            needsDisplay = true
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    private func updateHover(at p: CGPoint) {
        var newHover: (id: UUID, zone: Zone)?
        var newCut: (id: UUID, time: Double)?
        var newCursor = NSCursor.arrow

        if p.y < TimelineLayout.ruler {
            newCursor = .arrow
        } else if model.tool == .cut {
            newCursor = Cursors.cut
            if let h = hit(at: p) {
                var t = time(atX: p.x)
                let others = model.project.snapTargets(excluding: [h.clip.id]) + [model.playhead]
                if let s = snap([t], to: others, pixels: 6) { t += s.delta } else { t = model.project.snapFrame(t) }
                let minDur = 0.5 / model.project.fps
                if t > h.clip.start + minDur, t < h.clip.end - minDur {
                    newCut = (h.clip.id, t)
                    newHover = (h.clip.id, .body)
                }
            }
        } else if let h = hit(at: p) {
            newHover = (h.clip.id, h.zone)
            switch h.zone {
            case .left, .right: newCursor = .resizeLeftRight
            case .fadeIn, .fadeOut: newCursor = .pointingHand
            case .gain: newCursor = .resizeUpDown
            case .body: newCursor = .arrow
            }
        }

        let changed = newHover?.id != hover?.id || newHover?.zone != hover?.zone
            || newCut?.id != cutHover?.id || newCut?.time != cutHover?.time
        hover = newHover
        cutHover = newCut
        if changed { needsDisplay = true }
        if newCursor !== cursor {
            cursor = newCursor
        }
        cursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        model.skim(to: nil)
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        let extend = event.modifierFlags.contains(.shift)

        if p.y < TimelineLayout.ruler {
            drag = .scrub
            scrub(to: p)
            return
        }

        if model.tool == .cut {
            updateHover(at: p)
            if let cut = cutHover {
                model.split(clip: cut.id, at: cut.time)
                cutHover = nil
                needsDisplay = true
            }
            return
        }

        guard let h = hit(at: p) else {
            if !extend { model.selection = [] }
            drag = .marquee(origin: CGPoint(x: p.x + view.scrollX, y: p.y + view.scrollY), base: model.selection)
            return
        }

        let group = model.project.unlocked(model.project.linked([h.clip.id]))
        switch h.zone {
        case .body:
            if extend {
                if model.selection.contains(h.clip.id) { model.selection.subtract(group) } else { model.selection.formUnion(group) }
                return
            }
            if !model.selection.contains(h.clip.id) { model.selection = group }
            drag = .pendingMove(grabbed: h.clip, point: p, time: time(atX: p.x))
        case .left, .right:
            if !model.selection.contains(h.clip.id) { model.selection = group }
            let originals = model.project.clips.filter { group.contains($0.id) }
            drag = .trim(grabbed: h.clip, left: h.zone == .left, time: time(atX: p.x), originals: originals)
        case .fadeIn, .fadeOut:
            drag = .fade(id: h.clip.id, fadeIn: h.zone == .fadeIn)
        case .gain:
            if event.clickCount == 2 {
                model.mutate { proj in
                    if let i = proj.index(of: h.clip.id) { proj.clips[i].gainDB = 0 }
                }
                return
            }
            drag = .gain(id: h.clip.id, startY: p.y, startNorm: Self.gainNorm(h.clip.gainDB), height: h.rect.height)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        lastDragPoint = p
        handleDrag(at: p)
        switch drag {
        case .scrub, .move, .trim, .marquee: updateAutoscroll(p)
        default: break
        }
    }

    private func handleDrag(at p: CGPoint) {
        switch drag {
        case .none:
            break
        case .scrub:
            scrub(to: p)
        case .pendingMove(let grabbed, let start, let t0):
            guard abs(p.x - start.x) > 3 || abs(p.y - start.y) > 3 else { return }
            let ids = model.project.unlocked(model.project.linked(model.selection))
            let originals = model.project.clips.filter { ids.contains($0.id) }
            moveTrackDelta = 0
            drag = .move(grabbed: grabbed, time: t0, originals: originals)
            NSCursor.closedHand.set()
            updateMove(grabbed: grabbed, startTime: t0, originals: originals, p: p)
        case .move(let grabbed, let t0, let originals):
            updateMove(grabbed: grabbed, startTime: t0, originals: originals, p: p)
        case .trim(let grabbed, let left, let t0, let originals):
            updateTrim(grabbed: grabbed, left: left, startTime: t0, originals: originals, p: p)
        case .fade(let id, let fadeIn):
            let t = time(atX: p.x)
            model.live(autoCommit: false) { proj in
                guard let i = proj.index(of: id) else { return }
                var c = proj.clips[i]
                if fadeIn {
                    c.fadeIn = min(max(0, proj.snapFrame(t - c.start)), c.duration - c.fadeOut)
                } else {
                    c.fadeOut = min(max(0, proj.snapFrame(c.end - t)), c.duration - c.fadeIn)
                }
                proj.clips[i] = c
            }
            if let c = model.project.clip(id) {
                bubble = (String(format: "%.2fs", fadeIn ? c.fadeIn : c.fadeOut), CGPoint(x: p.x, y: p.y - 22))
            }
            needsDisplay = true
        case .gain(let id, let startY, let startNorm, let height):
            let db = Self.gainDB(norm: startNorm + (p.y - startY) / height)
            let value = db <= -59.5 ? -60 : db
            model.live(autoCommit: false) { proj in
                if let i = proj.index(of: id) { proj.clips[i].gainDB = value }
            }
            bubble = (formatDB(value), CGPoint(x: p.x + 12, y: p.y - 22))
            needsDisplay = true
        case .marquee(let origin, let base):
            let current = CGPoint(x: p.x + view.scrollX, y: p.y + view.scrollY)
            let content = CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                                 width: abs(origin.x - current.x), height: abs(origin.y - current.y))
            let r = content.offsetBy(dx: -view.scrollX, dy: -view.scrollY)
            marquee = r
            var ids = base
            for c in model.project.clips where !model.project.isLocked(c.trackID) {
                if let cr = rect(for: c), cr.intersects(r) { ids.insert(c.id) }
            }
            ids = model.project.unlocked(model.project.linked(ids))
            if ids != model.selection { model.selection = ids }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        let finished = drag
        drag = .none
        switch finished {
        case .move, .trim:
            let moved = overrides
            overrides = [:]
            if !moved.isEmpty {
                model.mutate { proj in
                    for (id, c) in moved {
                        if let i = proj.index(of: id) { proj.clips[i] = c }
                    }
                    proj.materializeTokens()
                    proj.resolveOverlaps(keeping: Set(moved.keys))
                }
            }
        case .fade, .gain:
            model.commitLive()
        default:
            break
        }
        snapLine = nil
        marquee = nil
        bubble = nil
        scrubReadout = nil
        lastScrubSnap = nil
        needsDisplay = true
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    private func scrub(to p: CGPoint) {
        var t = max(0, time(atX: p.x))
        let s = snap([t], to: model.project.snapTargets(excluding: []), pixels: 6)
        if let s { t += s.delta }
        if let target = s?.target, target != lastScrubSnap { Self.tap() }
        lastScrubSnap = s?.target
        model.seek(to: t)
        model.scrubSound(at: model.playhead)
        scrubReadout = model.playhead
        needsDisplay = true
    }

    private func updateMove(grabbed: Clip, startTime: Double, originals: [Clip], p: CGPoint) {
        let project = model.project
        let ids = Set(originals.map(\.id))
        let minStart = originals.map(\.start).min() ?? 0
        var dt = max(time(atX: p.x) - startTime, -minStart)
        snapLine = nil
        var snapped = false
        var candidates: [Double] = []
        for c in originals {
            candidates.append(c.start + dt)
            candidates.append(c.end + dt)
        }
        if let s = snap(candidates, to: project.snapTargets(excluding: ids) + [model.playhead]), minStart + dt + s.delta >= -1e-9 {
            dt += s.delta
            snapLine = s.target
            snapped = true
        }
        if !snapped {
            dt = max(project.snapFrame(grabbed.start + dt) - grabbed.start, -minStart)
        }

        let kind = grabbed.kind.trackKind
        let tracks = project.tracks(kind)
        let previousDelta = moveTrackDelta
        if let gi = project.trackIndex(grabbed.trackID, kind: kind) {
            switch lane(atY: p.y) {
            case .track(let t, let i) where t.kind == kind: moveTrackDelta = i - gi
            case .newVideo where kind == .video: moveTrackDelta = tracks.count - gi
            case .newAudio where kind == .audio: moveTrackDelta = tracks.count - gi
            default: break
            }
        }
        let indices = originals.filter { $0.kind.trackKind == kind }.compactMap { project.trackIndex($0.trackID, kind: kind) }
        if let lo = indices.min(), let hi = indices.max() {
            moveTrackDelta = max(-lo, min(moveTrackDelta, tracks.count - hi))
        }
        // Clips can't be moved onto a locked track.
        if indices.contains(where: { i in tracks.indices.contains(i + moveTrackDelta) && tracks[i + moveTrackDelta].locked }) {
            moveTrackDelta = previousDelta
        }

        var out: [UUID: Clip] = [:]
        for var c in originals {
            c.start = max(0, c.start + dt)
            if c.kind.trackKind == kind, let i = project.trackIndex(c.trackID, kind: kind) {
                let ni = i + moveTrackDelta
                c.trackID = ni >= tracks.count ? (kind == .video ? TrackToken.newVideo : TrackToken.newAudio) : tracks[max(0, ni)].id
            }
            out[c.id] = c
        }
        overrides = out
        needsDisplay = true
    }

    private func updateTrim(grabbed: Clip, left: Bool, startTime: Double, originals: [Clip], p: CGPoint) {
        if model.sticky { return updateStickyTrim(grabbed: grabbed, left: left, startTime: startTime, originals: originals, p: p) }
        let project = model.project
        let ids = Set(originals.map(\.id))
        let edge = left ? grabbed.start : grabbed.end
        var d = time(atX: p.x) - startTime
        snapLine = nil
        var snapTarget: Double?
        if let s = snap([edge + d], to: project.snapTargets(excluding: ids) + [model.playhead]) {
            d += s.delta
            snapTarget = s.target
        } else {
            d = project.snapFrame(edge + d) - edge
        }
        var lo = -Double.infinity, hi = Double.infinity
        for c in originals {
            let range = project.trimLimits(c, left: left, excluding: ids)
            lo = max(lo, range.lowerBound)
            hi = min(hi, range.upperBound)
        }
        let clamped = min(max(d, lo), max(lo, hi))
        if clamped == d { snapLine = snapTarget }
        d = clamped

        var out: [UUID: Clip] = [:]
        for var c in originals {
            if left { c.trimHead(to: c.start + d) } else { c.trimTail(to: c.end + d) }
            out[c.id] = c
        }
        overrides = out
        if let g = out[grabbed.id] {
            bubble = (Timecode.string(g.duration, fps: project.fps), CGPoint(x: p.x, y: p.y - 22))
        }
        needsDisplay = true
    }

    /// Trimming with sticky edges: the clip keeps its start (trimming the head takes content off the
    /// front instead of moving the clip), and everything touching its end follows the new end.
    private func updateStickyTrim(grabbed: Clip, left: Bool, startTime: Double, originals: [Clip], p: CGPoint) {
        let project = model.project
        let ids = Set(originals.map(\.id))
        let edge = left ? grabbed.start : grabbed.end
        var d = time(atX: p.x) - startTime
        snapLine = nil
        var snapTarget: Double?
        if let s = snap([edge + d], to: project.snapTargets(excluding: ids) + [model.playhead]) {
            d += s.delta
            snapTarget = s.target
        } else {
            d = project.snapFrame(edge + d) - edge
        }
        // Only the clip's own length and source limit what's possible; neighbours move out of the way.
        let minDur = max(Project.minClip, 1 / project.fps)
        var lo = -Double.infinity, hi = Double.infinity
        for c in originals {
            if left {
                if c.kind.usesSource { lo = max(lo, -c.sourceStart / c.speed) }
                hi = min(hi, c.duration - minDur)
            } else {
                lo = max(lo, minDur - c.duration)
                if let limit = project.sourceLimit(c) { hi = min(hi, (limit - c.sourceStart) / c.speed - c.duration) }
            }
        }
        let clamped = min(max(d, lo), max(lo, hi))
        if clamped == d { snapLine = snapTarget }

        func result(_ d: Double) -> [UUID: Clip] {
            var edited: [UUID: Clip] = [:]
            for var c in originals {
                if left {
                    let start = c.start
                    c.trimHead(to: c.start + d)
                    c.start = start
                } else {
                    c.trimTail(to: c.end + d)
                }
                edited[c.id] = c
            }
            return edited.merging(project.carried(by: edited)) { a, _ in a }
        }
        var out = result(clamped)
        if !project.fits(out) {
            // Something carried along would hit a clip that isn't moving: go as far as fits.
            snapLine = nil
            var ok = 0.0, bad = clamped
            for _ in 0..<24 {
                let mid = (ok + bad) / 2
                if project.fits(result(mid)) { ok = mid } else { bad = mid }
            }
            out = result(ok)
        }
        overrides = out
        if let g = out[grabbed.id] {
            bubble = (Timecode.string(g.duration, fps: project.fps), CGPoint(x: p.x, y: p.y - 22))
        }
        needsDisplay = true
    }

    // MARK: Autoscroll while dragging

    private func updateAutoscroll(_ p: CGPoint) {
        let margin: CGFloat = 26
        var v: CGFloat = 0
        if p.x > bounds.width - margin {
            v = min(34, (p.x - (bounds.width - margin)) * 0.6 + 4)
        } else if p.x < margin, view.scrollX > 0 {
            v = -min(34, (margin - p.x) * 0.6 + 4)
        }
        autoscrollVelocity = v
        if v == 0 {
            stopAutoscroll()
        } else if autoscrollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setScroll(x: self.view.scrollX + self.autoscrollVelocity, y: self.view.scrollY)
                    self.handleDrag(at: self.lastDragPoint)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoscrollTimer = timer
        }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: Scrolling & zoom

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let dy = event.scrollingDeltaY * (precise ? 1 : 8)
            model.zoom(by: exp(dy * 0.012))
            return
        }
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !precise {
            dx *= 12
            dy *= 12
            if abs(dx) < 0.01 {
                dx = dy
                dy = 0
            }
        }
        // Lock to the dominant axis so a sideways swipe never nudges the rows (and vice versa).
        if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
        setScroll(x: view.scrollX - dx, y: view.scrollY - dy)
    }

    override func magnify(with event: NSEvent) {
        model.zoom(by: 1 + event.magnification)
    }

    // MARK: Responder actions

    override func selectAll(_ sender: Any?) {
        model.selectAll()
    }

    @objc func delete(_ sender: Any?) {
        model.deleteSelection()
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let model = self.model

        if let h = hit(at: p) {
            if !model.selection.contains(h.clip.id) { model.selection = model.project.linked([h.clip.id]) }
            let t = model.playhead
            menu.addItem(ActionItem("Split at Playhead", enabled: t > h.clip.start && t < h.clip.end) { model.splitAtPlayhead() })
            menu.addItem(ActionItem("Detach Audio", enabled: model.selectionIsLinked) { model.detachAudio() })
            if h.clip.kind.usesSource {
                let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                for pct in [25, 50, 100, 200, 400, 800, 1600, 3000] {
                    sub.addItem(ActionItem("\(pct)%", checked: abs(h.clip.speed * 100 - Double(pct)) < 0.5) { model.setSpeed(Double(pct) / 100) })
                }
                speed.submenu = sub
                menu.addItem(speed)
            }
            // Transitions on the cuts either side of this clip.
            if h.clip.kind != .audio {
                let project = model.project
                func transitionMenu(_ title: String, into clip: Clip) -> NSMenuItem {
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    let sub = NSMenu()
                    sub.autoenablesItems = false
                    sub.addItem(ActionItem("None", checked: clip.transitionIn == nil) { model.setTransition(into: clip.id, nil) })
                    sub.addItem(.separator())
                    for kind in TransitionKind.allCases {
                        sub.addItem(ActionItem(kind.label, checked: clip.transitionIn?.kind == kind) {
                            var t = clip.transitionIn ?? Transition()
                            t.kind = kind
                            model.setTransition(into: clip.id, t)
                        })
                    }
                    item.submenu = sub
                    return item
                }
                if project.previous(touching: h.clip) != nil { menu.addItem(transitionMenu("Transition In", into: h.clip)) }
                if let next = project.next(touching: h.clip) { menu.addItem(transitionMenu("Transition Out", into: next)) }
            }
            if h.clip.kind == .audio {
                menu.addItem(ActionItem("Even Out Levels") { model.evenOutLevels() })
            }
            if h.clip.fadeIn > 0 || h.clip.fadeOut > 0 {
                menu.addItem(ActionItem("Remove Fades") {
                    let ids = model.selection
                    model.mutate { proj in
                        for i in proj.clips.indices where ids.contains(proj.clips[i].id) {
                            proj.clips[i].fadeIn = 0
                            proj.clips[i].fadeOut = 0
                        }
                    }
                })
            }
            menu.addItem(.separator())
            menu.addItem(ActionItem("Delete") { model.deleteSelection() })
            menu.addItem(ActionItem("Ripple Delete") { model.deleteSelection(ripple: true) })
        } else {
            menu.addItem(ActionItem("Add Video Track") { model.addTrack(.video) })
            menu.addItem(ActionItem("Add Audio Track") { model.addTrack(.audio) })
            if case .track(let track, _) = lane(atY: p.y), model.project.tracks(track.kind).count > 1 {
                menu.addItem(.separator())
                menu.addItem(ActionItem("Delete Track") { model.removeTrack(track.id) })
            }
        }
        return menu
    }

    // MARK: Drag & drop

    private func payload(from sender: NSDraggingInfo) -> DragPayload? {
        if let s = sender.draggingPasteboard.string(forType: .string), s.hasPrefix("cutandplay:") {
            let body = String(s.dropFirst("cutandplay:".count))
            if body == "solid" { return .solid }
            if body == "text" { return .text }
            if let id = UUID(uuidString: body) { return .asset(id) }
        }
        return model.dragPayload
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let hasFiles = sender.draggingPasteboard.types?.contains(.fileURL) ?? false
        let payload = hasFiles ? nil : self.payload(from: sender)
        guard hasFiles || payload != nil else { return [] }

        let project = model.project
        let vTracks = project.videoTracks, aTracks = project.audioTracks
        guard !vTracks.isEmpty, !aTracks.isEmpty else { return [] }
        var vTrack = vTracks[0].id, aTrack = aTracks[0].id
        var overAudio = false
        switch lane(atY: p.y) {
        case .track(let t, let i) where t.kind == .video:
            vTrack = t.id
            aTrack = aTracks[min(i, aTracks.count - 1)].id
        case .track(let t, let i):
            aTrack = t.id
            vTrack = vTracks[min(i, vTracks.count - 1)].id
            overAudio = true
        case .newVideo:
            vTrack = TrackToken.newVideo
            aTrack = aTracks[min(vTracks.count, aTracks.count - 1)].id
        case .newAudio:
            aTrack = TrackToken.newAudio
            vTrack = vTracks[min(aTracks.count, vTracks.count - 1)].id
            overAudio = true
        case .none:
            break
        }

        // Nothing lands on a locked track: use the nearest open one, or a new track.
        func open(_ id: UUID, _ kind: TrackKind) -> UUID {
            guard project.isLocked(id) else { return id }
            return project.tracks(kind).first { !$0.locked }?.id ?? (kind == .video ? TrackToken.newVideo : TrackToken.newAudio)
        }
        vTrack = open(vTrack, .video)
        aTrack = open(aTrack, .audio)

        let duration = payload.map { model.payloadDuration($0) } ?? 5
        var start = max(0, time(atX: p.x))
        if let s = snap([start, start + duration], to: project.snapTargets(excluding: []) + [model.playhead]), start + s.delta >= -1e-9 {
            start = max(0, start + s.delta)
            snapLine = s.target
        } else {
            snapLine = nil
            start = project.snapFrame(start)
        }

        if let payload {
            ghosts = model.makeClips(payload, at: start, videoTrack: vTrack, audioTrack: aTrack)
        } else {
            ghosts = [Clip(trackID: overAudio ? aTrack : vTrack, kind: overAudio ? .audio : .video, start: start, duration: duration)]
        }
        dropInfo = (vTrack, aTrack, start)
        needsDisplay = true
        return .copy
    }

    private func clearDrop() {
        ghosts = []
        dropInfo = nil
        snapLine = nil
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        _ = updateDrop(sender)
        guard let info = dropInfo else { return false }
        let urls = fileURLs(from: sender)
        let pending = ghosts
        clearDrop()
        if !urls.isEmpty {
            let model = self.model
            model.importFiles(urls) { assets in
                var t = info.start
                var clips: [Clip] = []
                for a in assets {
                    let payload = DragPayload.asset(a.id)
                    clips += model.makeClips(payload, at: t, videoTrack: info.video, audioTrack: info.audio)
                    t += model.payloadDuration(payload)
                }
                model.insert(clips)
            }
            return true
        }
        guard !pending.isEmpty else { return false }
        model.insert(pending)
        model.dragPayload = nil
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Drawing

    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
        .foregroundColor: NSColor(white: 1, alpha: 0.95),
    ]
    private static let rulerAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: Theme.NS.textFaint,
    ]
    private static let bubbleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let project = model.project
        layout = TimelineLayout(project: project, rowHeight: view.rowHeight)
        let ruler = TimelineLayout.ruler

        Theme.NS.bg.setFill()
        bounds.fill()

        // Lanes
        for row in layout.rows {
            let r = CGRect(x: 0, y: ruler + row.y - view.scrollY, width: bounds.width, height: row.height)
            guard r.maxY > ruler, r.minY < bounds.height else { continue }
            let off = row.track.locked || (row.track.kind == .video ? row.track.hidden : !project.isAudible(row.track))
            (off ? Theme.NS.bg.blended(withFraction: 0.4, of: Theme.NS.lane)! : Theme.NS.lane).setFill()
            r.fill()
        }

        // An empty timeline says how to fill it, across V1.
        if project.clips.isEmpty, ghosts.isEmpty, let v1 = project.videoTracks.first, let band = layout.band(for: v1.id) {
            let hint = NSAttributedString(string: "Drag media here, or double-click it in the library", attributes: Self.hintAttrs)
            let size = hint.size()
            let y = ruler + band.y - view.scrollY + (band.height - size.height) / 2
            hint.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: y))
        }

        // "New track" drop zones
        let targets = Set(ghosts.map(\.trackID)).union(overrides.values.map(\.trackID))
        for (token, zoneY) in [(TrackToken.newVideo, layout.videoZoneY), (TrackToken.newAudio, layout.audioZoneY)] where targets.contains(token) {
            let r = CGRect(x: 0, y: ruler + zoneY - view.scrollY, width: bounds.width, height: TimelineLayout.zone)
            Theme.NS.accent.withAlphaComponent(0.1).setFill()
            r.fill()
        }
        // Highlight the lanes a drag will land on
        for row in layout.rows where targets.contains(row.track.id) {
            let r = CGRect(x: 0, y: ruler + row.y - view.scrollY, width: bounds.width, height: row.height)
            NSColor(white: 1, alpha: 0.035).setFill()
            r.fill()
        }

        // Clips
        let lifted = Set(overrides.keys)
        for c in project.clips where !lifted.contains(c.id) {
            drawClip(c, ctx: ctx, alpha: project.isLocked(c.trackID) ? 0.45 : 1)
        }
        for c in overrides.values {
            drawClip(c, ctx: ctx, alpha: 0.82)
        }
        for c in ghosts {
            drawClip(c, ctx: ctx, alpha: 0.55)
        }

        // Transitions: a hatched block over the stretch each one covers.
        for b in project.clips where b.transitionIn != nil && !lifted.contains(b.id) {
            guard let a = project.previous(touching: b), !lifted.contains(a.id),
                  let span = project.transitionSpan(from: a, into: b), let band = rect(for: b) else { continue }
            let r = CGRect(x: x(span.start), y: band.minY + 3, width: max(4, x(span.end) - x(span.start)), height: band.height - 6)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
            ctx.setLineWidth(2)
            var sx = r.minX - r.height
            while sx < r.maxX {
                ctx.move(to: CGPoint(x: sx, y: r.maxY))
                ctx.addLine(to: CGPoint(x: sx + r.height, y: r.minY))
                sx += 7
            }
            ctx.strokePath()
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(model.selection.contains(b.id) ? 1 : 0.75).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }

        // Skim line: where the viewer is showing, while the playhead stays put.
        if let t = model.skimTime {
            let sx = x(t)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.55).cgColor)
            ctx.fill(CGRect(x: sx - 0.5, y: TimelineLayout.ruler, width: 1, height: bounds.height - TimelineLayout.ruler))
            ctx.fill(CGRect(x: sx - 3, y: TimelineLayout.ruler - 6, width: 6, height: 6))
        }

        // Cut preview
        if let cut = cutHover {
            let group = project.linked([cut.id])
            for c in project.clips where group.contains(c.id) && cut.time > c.start && cut.time < c.end {
                guard let r = rect(for: c) else { continue }
                let cx = x(cut.time)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: cx - 0.75, y: r.minY, width: 1.5, height: r.height))
            }
        }

        // Snap guide
        if let s = snapLine {
            // A white line with a dot at each end of the clips it joins.
            let sx = x(s)
            let ys = (Array(overrides.values) + ghosts).compactMap { rect(for: $0) }
            let top = max(ruler, (ys.map(\.minY).min() ?? ruler) - 4)
            let bottom = min(bounds.height, (ys.map(\.maxY).max() ?? bounds.height) + 4)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.9).cgColor)
            ctx.fill(CGRect(x: sx - 0.5, y: top, width: 1, height: bottom - top))
            for y in [top, bottom] { ctx.fillEllipse(in: CGRect(x: sx - 3, y: y - 3, width: 6, height: 6)) }
        }

        // Marquee
        if let m = marquee {
            ctx.setFillColor(Theme.NS.accent.withAlphaComponent(0.12).cgColor)
            ctx.fill(m)
            ctx.setStrokeColor(Theme.NS.accent.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(m.insetBy(dx: 0.5, dy: 0.5))
        }

        drawRuler(ctx, project: project)

        // Value bubble
        if let b = bubble {
            let text = NSAttributedString(string: b.text, attributes: Self.bubbleAttrs)
            let size = text.size()
            var r = CGRect(x: b.point.x - size.width / 2 - 7, y: b.point.y - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
            r.origin.x = min(max(4, r.origin.x), bounds.width - r.width - 4)
            r.origin.y = max(ruler + 2, r.origin.y)
            ctx.setFillColor(NSColor(white: 0.05, alpha: 0.92).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            text.draw(at: CGPoint(x: r.minX + 7, y: r.minY + 3))
        }

        // The playhead's time beside its flag while it's being dragged.
        if let t = scrubReadout {
            let text = NSAttributedString(string: Timecode.string(t, fps: project.fps), attributes: Self.readoutAttrs)
            let size = text.size()
            var r = CGRect(x: x(t) + 10, y: 4, width: size.width + 12, height: size.height + 4)
            if r.maxX > bounds.width - 4 { r.origin.x = x(t) - 10 - r.width }
            ctx.setFillColor(Theme.NS.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            text.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2))
        }
    }

    private static let hintAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5),
        .foregroundColor: NSColor(hex: 0x3E3E3C),
    ]

    private static let readoutAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private func drawRuler(_ ctx: CGContext, project: Project) {
        let ruler = TimelineLayout.ruler
        Theme.NS.panel.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: ruler).fill()
        ctx.setFillColor(Theme.NS.stroke.cgColor)
        ctx.fill(CGRect(x: 0, y: ruler - 1, width: bounds.width, height: 1))

        let fps = project.fps
        let f = 1 / fps
        let steps: [(Double, Int)] = [
            (f, 1), (2 * f, 2), (5 * f, 5), (10 * f, 5), (1, 4), (2, 4), (5, 5), (10, 5), (15, 3), (30, 6),
            (60, 6), (120, 4), (300, 5), (600, 5), (900, 3), (1800, 6), (3600, 6), (7200, 4), (18000, 5), (36000, 5),
        ]
        var step = steps.last!
        for s in steps where CGFloat(s.0) * pps >= 86 && (s.0 >= 1 || s.0 < 0.5) {
            step = s
            break
        }
        let (major, subdivisions) = step
        let t0 = time(atX: 0), t1 = time(atX: bounds.width)
        var k = Int(floor(t0 / major))
        let showFrames = major < 1
        while Double(k) * major <= t1 {
            let t = Double(k) * major
            let px = x(t)
            if t >= 0 {
                ctx.setFillColor(NSColor(white: 1, alpha: 0.28).cgColor)
                ctx.fill(CGRect(x: px.rounded(), y: ruler - 9, width: 1, height: 8))
                var label = Timecode.short(t)
                if showFrames {
                    let frames = Int((t * fps).rounded()) % max(1, Int(fps.rounded()))
                    label = Timecode.short(floor(t + 1e-6)) + String(format: ":%02d", frames)
                }
                (label as NSString).draw(at: CGPoint(x: px + 5, y: 5), withAttributes: Self.rulerAttrs)
            }
            if subdivisions > 1 {
                ctx.setFillColor(NSColor(white: 1, alpha: 0.13).cgColor)
                for j in 1..<subdivisions {
                    let mt = t + major * Double(j) / Double(subdivisions)
                    if mt >= 0 { ctx.fill(CGRect(x: x(mt).rounded(), y: ruler - 5, width: 1, height: 4)) }
                }
            }
            k += 1
        }
    }

    private func drawClip(_ c: Clip, ctx: CGContext, alpha: CGFloat) {
        guard let full = rect(for: c) else { return }
        guard full.maxX > -4, full.minX < bounds.width + 4, full.maxY > TimelineLayout.ruler, full.minY < bounds.height else { return }
        let r = full.insetBy(dx: 0, dy: 2).insetBy(dx: min(0.5, full.width / 4), dy: 0)
        let base = Theme.NS.clip(c.kind)
        let selected = model.selection.contains(c.id)
        let hovered = hover?.id == c.id
        let zone = hovered ? hover?.zone : nil
        let radius = min(7, r.width / 2)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let visible = r.intersection(bounds.insetBy(dx: -2, dy: 0))
        let asset = model.project.asset(c.assetID)
        let offline = c.kind.usesSource || c.kind == .image ? (asset.map { model.media.isOffline($0) } ?? true) : false

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.addPath(path)
        ctx.clip()

        let fill = offline && !ghosts.contains(where: { $0.id == c.id })
            ? NSColor(hex: 0x5A1F1F)
            : base
        ctx.setFillColor(fill.cgColor)
        ctx.fill(r)

        switch c.kind {
        case .video:
            if let asset { drawFilmstrip(c, asset: asset, in: r, visible: visible, ctx: ctx) }
        case .image:
            if let img = model.media.still(c.assetID) {
                let tileW = max(20, r.height * CGFloat(img.width) / CGFloat(max(1, img.height)))
                var tx = r.minX + floor(max(0, visible.minX - r.minX) / tileW) * tileW
                ctx.setAlpha(alpha * 0.85)
                while tx < visible.maxX {
                    drawImage(img, fill: CGRect(x: tx, y: r.minY, width: tileW, height: r.height), ctx: ctx)
                    tx += tileW
                }
                ctx.setAlpha(alpha)
            }
        case .audio:
            drawWaveform(c, in: r, visible: visible, ctx: ctx)
        case .solid:
            ctx.setFillColor(c.color.nsColor.cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.maxY - 5, width: r.width, height: 5))
        case .text:
            break
        }

        // Title strip
        if r.width > 26, r.height > 20 {
            if c.kind == .video || c.kind == .image {
                ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 17))
            }
            var label = model.project.name(of: c)
            if abs(c.speed - 1) > 0.001 { label += "   \(Int((c.speed * 100).rounded()))%" }
            if c.kind == .audio, abs(c.gainDB) > 0.05 { label += "   " + formatDB(c.gainDB) }
            var lx = max(r.minX, 0) + 8
            if r.width > 36 { lx = max(lx, fadeHandleX(c, r, fadeIn: true) + 10) }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: r.minX, y: r.minY, width: max(0, r.width - 16), height: 18))
            (label as NSString).draw(at: CGPoint(x: lx, y: r.minY + 2.5), withAttributes: Self.labelAttrs)
            ctx.restoreGState()
        }

        // Fades
        for isIn in [true, false] {
            let w = CGFloat(isIn ? c.fadeIn : c.fadeOut) * pps
            guard w > 0.5 else { continue }
            let curve = isIn ? c.inCurve : c.outCurve
            let edge = isIn ? r.minX : r.maxX
            let dir: CGFloat = isIn ? 1 : -1
            let line = CGMutablePath()
            let steps = 24
            for i in 0...steps {
                let n = Double(i) / Double(steps)
                let pt = CGPoint(x: edge + dir * CGFloat(n) * w, y: r.maxY - CGFloat(curve.apply(n)) * r.height)
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            if let shade = line.mutableCopy() {
                shade.addLine(to: CGPoint(x: edge, y: r.minY))
                shade.closeSubpath()
                ctx.addPath(shade)
                ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
                ctx.fillPath()
            }
            ctx.addPath(line)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // Gain line
        if c.kind == .audio, r.width > 8 {
            let gy = (r.minY + Self.gainNorm(c.gainDB) * r.height).rounded() + 0.5
            let hot = zone == .gain
            ctx.setStrokeColor(NSColor(white: 1, alpha: hot ? 1 : 0.5).cgColor)
            ctx.setLineWidth(hot ? 2 : 1)
            ctx.move(to: CGPoint(x: r.minX, y: gy))
            ctx.addLine(to: CGPoint(x: r.maxX, y: gy))
            ctx.strokePath()
        }

        // Edge affordance
        if zone == .left || zone == .right {
            ctx.setFillColor(NSColor.white.cgColor)
            let ex = zone == .left ? r.minX : r.maxX - 3.5
            ctx.fill(CGRect(x: ex, y: r.minY, width: 3.5, height: r.height))
        }
        ctx.restoreGState()

        // Border
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        if selected {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
        } else if hovered {
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.6).cgColor)
            ctx.setLineWidth(1)
        } else {
            ctx.setStrokeColor(Theme.NS.clipStroke.cgColor)
            ctx.setLineWidth(1)
        }
        ctx.strokePath()

        // Fade handles
        if r.width > 36, alpha == 1, hovered || selected || c.fadeIn > 0 || c.fadeOut > 0 {
            for isIn in [true, false] {
                let active = (isIn ? c.fadeIn : c.fadeOut) > 0
                guard hovered || selected || active else { continue }
                let hot = zone == (isIn ? .fadeIn : .fadeOut)
                let hx = fadeHandleX(c, r, fadeIn: isIn)
                let rad: CGFloat = hot ? 5.5 : 4
                let dot = CGRect(x: hx - rad, y: r.minY + 8 - rad, width: rad * 2, height: rad * 2)
                ctx.setFillColor((hot ? Theme.NS.accent : NSColor.white).cgColor)
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: dot)
            }
        }
        ctx.restoreGState()
    }

    private func drawImage(_ img: CGImage, fill rect: CGRect, ctx: CGContext) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0 else { return }
        let s = max(rect.width / iw, rect.height / ih)
        let dw = iw * s, dh = ih * s
        let dr = CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: 0, y: dr.minY + dr.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: dr)
        ctx.restoreGState()
    }

    private func drawFilmstrip(_ c: Clip, asset: MediaAsset, in r: CGRect, visible: CGRect, ctx: CGContext) {
        guard visible.width > 0, asset.height > 0 else { return }
        let aspect = CGFloat(asset.width) / CGFloat(asset.height)
        let tileW = max(24, r.height * aspect)
        // Source seconds per tile: the smallest power of two that keeps tiles at least one thumbnail wide.
        var step = 1.0 / 16
        while CGFloat(step / c.speed) * pps < tileW, step < 16384 { step *= 2 }
        let srcAt = { (px: CGFloat) -> Double in c.sourceStart + Double((px - r.minX) / self.pps) * c.speed }
        var k = Int(floor(srcAt(visible.minX) / step))
        let kEnd = Int(ceil(srcAt(visible.maxX) / step))
        let w = CGFloat(step / c.speed) * pps
        var drawn = 0
        ctx.saveGState()
        ctx.setAlpha(0.88)
        while k <= kEnd, drawn < 240 {
            let ts = Double(k) * step
            let tx = r.minX + CGFloat((ts - c.sourceStart) / c.speed) * pps
            let sample = min(max(0, ts), max(0, asset.duration - 0.05))
            if let img = model.media.thumbnail(asset: asset.id, time: sample) {
                // Frames sit side by side with a 1pt dark gap, like a contact sheet.
                drawImage(img, fill: CGRect(x: tx, y: r.minY, width: max(1, w - 1), height: r.height), ctx: ctx)
            }
            k += 1
            drawn += 1
        }
        ctx.restoreGState()
    }

    private func drawWaveform(_ c: Clip, in r: CGRect, visible: CGRect, ctx: CGContext) {
        guard let id = c.assetID, let wf = model.media.waveforms[id], visible.width > 0, !wf.peaks.isEmpty else { return }
        let top = r.minY + 16, bottom = r.maxY - 3
        guard bottom - top > 6 else { return }
        let mid = (top + bottom) / 2, half = (bottom - top) / 2
        let gain = dbToLinear(c.gainDB)
        let secPerPx = Double(1 / pps) * c.speed
        var points: [(CGFloat, CGFloat)] = []
        points.reserveCapacity(Int(visible.width) + 2)
        var px = floor(visible.minX)
        let count = wf.peaks.count
        while px <= visible.maxX {
            let t0 = c.sourceStart + Double(px - r.minX) * secPerPx
            let i0 = Int(t0 * wf.peaksPerSecond)
            let i1 = Int((t0 + secPerPx) * wf.peaksPerSecond)
            var peak: Float = 0
            if i0 < count, i1 >= 0 {
                let a = max(0, i0), b = min(count - 1, max(i0, i1))
                if a <= b {
                    let stride = max(1, (b - a) / 24)
                    var i = a
                    while i <= b {
                        if wf.peaks[i] > peak { peak = wf.peaks[i] }
                        i += stride
                    }
                }
            }
            points.append((px, CGFloat(min(1, Double(peak) * gain)) * half))
            px += 1
        }
        guard points.count > 1 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].0, y: mid - max(0.5, points[0].1)))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.0, y: mid - max(0.5, p.1))) }
        for p in points.reversed() { path.addLine(to: CGPoint(x: p.0, y: mid + max(0.5, p.1))) }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(Theme.NS.wave.withAlphaComponent(0.85).cgColor)
        ctx.fillPath()
    }
}
