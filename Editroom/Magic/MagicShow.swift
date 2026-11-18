import AppKit
import QuartzCore
import SwiftUI

// MARK: - Anchors

/// Marks a SwiftUI view so the magic overlay can find where it is in the window.
struct MagicAnchor: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.key = key
        return v
    }

    func updateNSView(_ v: AnchorView, context: Context) { v.key = key }

    final class AnchorView: NSView {
        var key = "" { didSet { MagicAnchors.register(self, key) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
enum MagicAnchors {
    private struct Weak { weak var view: NSView? }
    private static var views: [String: Weak] = [:]

    static func register(_ v: NSView, _ key: String) { views[key] = Weak(view: v) }

    /// Where the view is, in window coordinates.
    static func rect(_ key: String) -> NSRect? {
        guard let v = views[key]?.view, v.window != nil else { return nil }
        return v.convert(v.bounds, to: nil)
    }
}

// MARK: - The show

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Plays an edit plan as a swarm of cursors: each edit is handed to one of many fake cursors, which
/// travels to the control and drags it, while the change happens on the real timeline. The whole cut
/// is one undo step.
@MainActor
final class MagicShow: NSObject {
    static private(set) var current: MagicShow?
    static var isRunning: Bool { current != nil }

    /// Starts the show. `fromMouse` spawns the cursors from the mouse; otherwise from the Magic button.
    @discardableResult
    static func start(model: EditorModel, fromMouse: Bool) -> Bool {
        guard current == nil, let canvas = TimelineCanvas.current, let window = canvas.window else { return false }
        let offline = Set(model.project.assets.filter { model.media.isOffline($0) }.map(\.id))
        guard let plan = ScriptedPlanner.plan(for: model.project, offline: offline) else {
            NSSound.beep()
            return false
        }
        let show = MagicShow(model: model, plan: plan, window: window, canvas: canvas, fromMouse: fromMouse)
        current = show
        show.begin()
        return true
    }

    private struct Slot {
        let edit: MagicEdit
        let agent: Int
        let travelStart: Double
        let start: Double
        let end: Double
        var grab: CGPoint?
        var release: CGPoint?
        /// Where the cursor waits nearby if it gets there early, from where things will be.
        var hover: CGPoint?
    }

    private final class Agent {
        let color: NSColor
        let cursor = CALayer()
        let tag = CALayer()
        let tagText = CATextLayer()
        let ghost = CALayer()
        var slots: [Int] = []
        var label = ""
        var birth = 0.0
        var angle = 0.0
        /// Each cursor moves at its own pace.
        var speed = 1.0
        /// When it heads back to the button, and when it's gone.
        var home = 0.0
        var gone = 0.0
        init(color: NSColor) { self.color = color }
    }

    private final class Card {
        let clip: UUID
        let row: Int
        var slots: [Int] = []
        var frame: CGRect?
        var appear = 0.0
        var vanish = 0.0
        let layer = CALayer()
        let title = CATextLayer()
        let chip = CALayer()
        let chipText = CATextLayer()
        var knobs: [MagicGradeKey: (fill: CALayer, knob: CALayer, value: CATextLayer)] = [:]
        init(clip: UUID, row: Int) { self.clip = clip; self.row = row }
    }

    private let model: EditorModel
    private let plan: MagicPlan
    private let window: NSWindow
    private let canvas: TimelineCanvas
    private let fromMouse: Bool
    private var slots: [Slot] = []
    private var order: [Int] = []
    private var agents: [Agent] = []
    private var cards: [UUID: Card] = [:]
    private let overlay: NSWindow
    private let root = CALayer()
    private let status = CALayer()
    private let statusText = CATextLayer()
    private var link: CADisplayLink?
    private var monitor: Any?
    private var t0 = CACurrentMediaTime()
    private var skip = 0.0
    private var workEnd = 0.0
    private var showEnd = 0.0
    private var spawn = CGPoint.zero
    private var done = false
    /// The finished cut, and every clip as it's first dropped, for working out where things will be.
    private var finalProject = Project()
    private var staged: [UUID: Clip] = [:]
    private var lastFlash = -1.0
    private var flashIndex = -1
    private var frames = 0
    private var longestFrame = 0.0
    private var lastFrame = 0.0

    static let outro = 0.34
    static let homeTrip = 0.42
    static let cardHeight: CGFloat = 96
    static let cardGap: CGFloat = 6
    /// Grade panels sit in the inspector, stacked; this many fit at once.
    private var cardSlots = 4
    private var cardSize = CGSize(width: 290, height: 106)
    private var trackWidth: CGFloat { cardSize.width - Self.trackX - 46 }
    private static let trackX: CGFloat = 84
    private let backdrop = CALayer()
    private let backdropTitle = CATextLayer()
    private let backdropCount = CATextLayer()
    private var backdropSpan = (0.0, 0.0)
    /// The show runs slower than it's planned, so it lasts about this long.
    static let targetLength = 5.0
    private var pace = 1.0

    private init(model: EditorModel, plan: MagicPlan, window: NSWindow, canvas: TimelineCanvas, fromMouse: Bool) {
        self.model = model
        self.plan = plan
        self.window = window
        self.canvas = canvas
        self.fromMouse = fromMouse
        overlay = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
    }

    // MARK: Setup

    private func begin() {
        model.pause()
        model.selection = []
        model.rebuildSuspended = true

        // Lay the timeline out for the finished cut before anything lands on it.
        model.live(autoCommit: false) { $0 = plan.base }
        let total = plan.tasks.compactMap { task -> Double? in
            if case .place(let clips, _) = task.edit { return clips.map(\.end).max() }
            return nil
        }.max() ?? 10
        let tracks = CGFloat(plan.base.videoTracks.count + plan.base.audioTracks.count)
        let fit = (model.rowsVisible - TimelineLayout.fixedHeight - 8) / tracks - TimelineLayout.gap
        model.setView(rowHeight: min(62, fit))
        model.setView(pps: (model.view.viewWidth - 60) / CGFloat(total), scrollX: 0)
        model.centerRows()

        spawn = spawnPoint()
        schedule()
        // Make the grades' colour cubes now, not mid-show.
        for g in Set(finalProject.clips.compactMap(\.grade)) { _ = GradeBaker.cube(for: g) }
        buildOverlay()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, !self.done else { return e }
                self.fastForward()
                return nil
            }
        }
        t0 = CACurrentMediaTime()
        let link = overlay.contentView!.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        step()
    }

    /// How slow things are at a moment in the show: it starts unhurried and gets quicker.
    static func tempo(_ t: Double) -> Double { 0.72 + 1.1 * exp(-t / 0.8) }

    /// Hands every edit to a cursor. Cursors leave the button one at a time, each as it's needed, and
    /// each takes the next edit it can reach soonest, so they work and finish independently.
    private func schedule() {
        let tasks = plan.tasks
        for t in tasks { if case .place(let clips, _) = t.edit { for c in clips { staged[c.id] = c } } }
        finalProject = plan.base
        for t in tasks { t.edit.apply(&finalProject, 1) }

        let insp = inspectorRect
        cardSize = CGSize(width: insp.width - 24, height: Self.cardHeight)
        cardSlots = max(2, Int((insp.height - 60) / (Self.cardHeight + Self.cardGap)))
        // Grade panels take turns in the inspector's places.
        var slotFree = Array(repeating: 0.0, count: cardSlots)
        var cardLeft: [UUID: Int] = [:]
        var cardLast: [UUID: Double] = [:]
        for t in tasks where t.edit.isGradeCard { if let id = t.edit.clipID { cardLeft[id, default: 0] += 1 } }

        let count = min(64, max(14, Int(Double(tasks.count) / 2.4)))
        var rng = SeededRandom(seed: UInt64(tasks.count))
        for i in 0..<count {
            let hue = (Double(i) * 0.61803398875).truncatingRemainder(dividingBy: 1)
            let a = Agent(color: NSColor(hue: hue, saturation: 0.68, brightness: 0.97, alpha: 1))
            // Out of the button one after another, slowly at first, then faster.
            a.birth = 1.5 * (Double(i) / Double(count)).squareRoot()
            a.angle = rng.next() * 2 * .pi
            a.speed = 0.8 + rng.next() * 0.45
            agents.append(a)
        }
        var free = agents.map(\.birth)
        var pos = Array(repeating: spawn, count: count)
        var used = Array(repeating: false, count: count)
        var end = Array(repeating: -1.0, count: tasks.count)
        var remaining = Set(tasks.indices)
        slots = []

        func travel(_ a: Int, _ from: CGPoint, _ to: CGPoint, at t: Double) -> Double {
            let d = Double(hypot(to.x - from.x, to.y - from.y))
            return min(0.65, max(0.14, d / (2200 * agents[a].speed / Self.tempo(t))))
        }

        while !remaining.isEmpty {
            var best: (task: Int, ready: Double)?
            for i in remaining where tasks[i].after.allSatisfy({ end[$0] >= 0 }) {
                var ready = (tasks[i].after.map { end[$0] }.max() ?? 0) + tasks[i].delay
                if tasks[i].edit.isGradeCard, let id = tasks[i].edit.clipID {
                    // Waits for its panel to be in the inspector, or for a place to open up.
                    if let card = cards[id] { ready = max(ready, card.appear + 0.18 + tasks[i].delay) }
                    else { ready = max(ready, (slotFree.min() ?? 0) + 0.18 + tasks[i].delay) }
                }
                if best == nil || ready < best!.ready { best = (i, ready) }
            }
            guard let (ti, ready) = best else { break }
            let edit = tasks[ti].edit
            if edit.isGradeCard, let id = edit.clipID, cards[id] == nil {
                let j = slotFree.indices.min { slotFree[$0] < slotFree[$1] } ?? 0
                let card = Card(clip: id, row: j)
                card.appear = max(slotFree[j], ready - 0.18 - tasks[ti].delay)
                cards[id] = card
                slotFree[j] = .infinity
            }
            let (grab, release) = computePoints(edit)
            // The cursor that can get there first; a cursor already out beats a new one.
            var pick = 0, pickStart = Double.infinity, pickTravel = 0.0
            for a in 0..<count {
                let tr = travel(a, pos[a], grab, at: free[a])
                let start = max(ready, free[a] + tr)
                let better = start < pickStart - 1e-6 || (abs(start - pickStart) <= 1e-6 && used[a] && !used[pick])
                if better { pick = a; pickStart = start; pickTravel = tr }
            }
            let perform = edit.performTime * Self.tempo(pickStart) * (0.85 + rng.next() * 0.35)
            let finish = pickStart + perform
            slots.append(Slot(edit: edit, agent: pick, travelStart: pickStart - pickTravel, start: pickStart, end: finish))
            agents[pick].slots.append(slots.count - 1)
            free[pick] = finish + 0.03
            pos[pick] = release
            used[pick] = true
            end[ti] = finish
            remaining.remove(ti)
            if edit.isGradeCard, let id = edit.clipID, let card = cards[id] {
                card.slots.append(slots.count - 1)
                cardLast[id] = max(cardLast[id] ?? 0, finish)
                cardLeft[id, default: 1] -= 1
                if cardLeft[id] == 0 {
                    // Done: it leaves for its clip, and the next panel can take its place.
                    card.vanish = cardLast[id]! + 0.12
                    slotFree[card.row] = card.vanish + 0.18
                }
            }
        }
        order = slots.indices.sorted { slots[$0].start < slots[$1].start }
        workEnd = (slots.map(\.end).max() ?? 0) + 0.06

        // Each cursor goes home once it has nothing left to do.
        for a in agents {
            guard let last = a.slots.last else { continue }
            a.birth = slots[a.slots[0]].travelStart
            a.home = slots[last].end + 0.08 + rng.next() * 0.12
            a.gone = a.home + Self.homeTrip
        }
        showEnd = max(workEnd, agents.map(\.gone).max() ?? workEnd) + 0.05

        if let first = cards.values.map(\.appear).min(), let last = cards.values.map(\.vanish).max() {
            backdropSpan = (first - 0.15, last + 0.3)
        }
        pace = max(1, Self.targetLength / showEnd)
    }

    // MARK: Overlay

    private func buildOverlay() {
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        // A flipped, layer-backed view: AppKit keeps its layer's sublayers in top-left coordinates.
        let host = FlippedView(frame: NSRect(origin: .zero, size: window.frame.size))
        host.wantsLayer = true
        host.layer?.addSublayer(root)
        root.frame = host.bounds
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        overlay.contentView = host
        window.addChildWindow(overlay, ordered: .above)

        let scale = window.backingScaleFactor

        backdrop.backgroundColor = Theme.NS.panel.cgColor
        backdrop.opacity = 0
        for (layer, text, x, size, color) in [(backdropTitle, "Grade", 16.0, 13.0, Theme.NS.text), (backdropCount, "", 0.0, 11.0, Theme.NS.textDim)] {
            layer.contentsScale = scale
            layer.string = text
            layer.font = NSFont.systemFont(ofSize: size, weight: x > 0 ? .semibold : .medium)
            layer.fontSize = size
            layer.foregroundColor = color.cgColor
            layer.alignmentMode = x > 0 ? .left : .right
            backdrop.addSublayer(layer)
        }
        let insp = inspectorRect
        backdropTitle.frame = CGRect(x: 16, y: 15, width: 120, height: 17)
        backdropCount.frame = CGRect(x: insp.width - 136, y: 17, width: 120, height: 15)
        root.addSublayer(backdrop)
        for c in cards.values {
            buildCard(c, scale: scale)
            root.addSublayer(c.layer)
        }
        for a in agents {
            a.ghost.cornerRadius = 4
            a.ghost.masksToBounds = true
            a.ghost.borderWidth = 1.5
            a.ghost.borderColor = a.color.cgColor
            a.ghost.contentsGravity = .resizeAspectFill
            a.ghost.isHidden = true
            root.addSublayer(a.ghost)
        }
        for a in agents {
            a.cursor.contents = Self.cursorImage(a.color, scale: scale)
            a.cursor.contentsScale = scale
            a.cursor.bounds = CGRect(x: 0, y: 0, width: 18, height: 24)
            a.cursor.anchorPoint = CGPoint(x: 2 / 18, y: 2 / 24)
            a.cursor.isHidden = true
            a.tag.backgroundColor = a.color.blended(withFraction: 0.18, of: .black)?.cgColor
            a.tag.cornerRadius = 4
            a.tag.isHidden = true
            a.tagText.contentsScale = scale
            a.tagText.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            a.tagText.fontSize = 10
            a.tagText.foregroundColor = NSColor.white.cgColor
            a.tagText.alignmentMode = .center
            a.tag.addSublayer(a.tagText)
            root.addSublayer(a.tag)
            root.addSublayer(a.cursor)
        }

        status.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        status.cornerRadius = 13
        status.borderWidth = 1
        status.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        statusText.contentsScale = scale
        statusText.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        statusText.fontSize = 11
        statusText.foregroundColor = Theme.NS.text.cgColor
        statusText.alignmentMode = .center
        status.addSublayer(statusText)
        status.opacity = 0
        root.addSublayer(status)
    }

    private func buildCard(_ c: Card, scale: CGFloat) {
        let size = cardSize
        c.layer.bounds = CGRect(origin: .zero, size: size)
        c.layer.backgroundColor = NSColor(hex: 0x181818).cgColor
        c.layer.cornerRadius = 8
        c.layer.borderWidth = 1
        c.layer.borderColor = NSColor(white: 1, alpha: 0.09).cgColor
        c.layer.opacity = 0

        func text(_ s: String, _ frame: CGRect, size: CGFloat = 10, weight: NSFont.Weight = .medium,
                  color: NSColor = Theme.NS.textDim, align: CATextLayerAlignmentMode = .left) -> CATextLayer {
            let t = CATextLayer()
            t.contentsScale = scale
            t.string = s
            t.font = NSFont.systemFont(ofSize: size, weight: weight)
            t.fontSize = size
            t.foregroundColor = color.cgColor
            t.alignmentMode = align
            t.frame = frame
            c.layer.addSublayer(t)
            return t
        }

        let name = model.project.clip(c.clip).map { model.project.name(of: $0) }
            ?? plan.tasks.lazy.compactMap { t -> String? in
                if case .place(let clips, let asset) = t.edit, clips.contains(where: { $0.id == c.clip }) {
                    return self.plan.base.asset(asset)?.name
                }
                return nil
            }.first ?? "Clip"
        c.title.contentsScale = scale
        _ = text("GRADE", CGRect(x: 10, y: 8, width: 44, height: 12), size: 9, weight: .bold, color: Theme.NS.textFaint)
        let t = text(name, CGRect(x: 52, y: 7, width: size.width - 62, height: 13), size: 10.5, weight: .semibold, color: Theme.NS.text)
        t.truncationMode = .middle

        _ = text("Look", CGRect(x: 10, y: 27, width: 56, height: 13))
        c.chip.frame = CGRect(x: Self.trackX - 6, y: 24, width: size.width - Self.trackX - 4, height: 18)
        c.chip.cornerRadius = 5
        c.chip.backgroundColor = NSColor(hex: 0x232323).cgColor
        c.chip.borderWidth = 1
        c.chip.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        c.layer.addSublayer(c.chip)
        c.chipText.contentsScale = scale
        c.chipText.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        c.chipText.fontSize = 10
        c.chipText.foregroundColor = Theme.NS.textDim.cgColor
        c.chipText.frame = CGRect(x: 8, y: 2.5, width: c.chip.frame.width - 16, height: 13)
        c.chipText.string = "None"
        c.chip.addSublayer(c.chipText)

        for (i, key) in MagicGradeKey.allCases.enumerated() {
            let y = Self.rowY(i)
            _ = text(key.label, CGRect(x: 10, y: y - 7, width: 70, height: 13))
            let track = CALayer()
            track.frame = CGRect(x: Self.trackX, y: y - 1, width: trackWidth, height: 2)
            track.cornerRadius = 1
            track.backgroundColor = NSColor(white: 1, alpha: 0.13).cgColor
            c.layer.addSublayer(track)
            let fill = CALayer()
            fill.backgroundColor = Theme.NS.text.cgColor
            fill.cornerRadius = 1
            c.layer.addSublayer(fill)
            let knob = CALayer()
            knob.bounds = CGRect(x: 0, y: 0, width: 11, height: 11)
            knob.cornerRadius = 5.5
            knob.backgroundColor = Theme.NS.text.cgColor
            knob.borderWidth = 2
            knob.borderColor = NSColor(hex: 0x161616).cgColor
            c.layer.addSublayer(knob)
            let value = text("0", CGRect(x: size.width - 40, y: y - 7, width: 30, height: 13), size: 9.5, color: Theme.NS.textFaint, align: .right)
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
            c.knobs[key] = (fill, knob, value)
        }
    }

    private static func rowY(_ i: Int) -> CGFloat { 54 + CGFloat(i) * 15 }

    private func knobX(_ key: MagicGradeKey, _ v: Double) -> CGFloat {
        let r = key.range
        return Self.trackX + CGFloat((v - r.lowerBound) / (r.upperBound - r.lowerBound)) * trackWidth
    }

    private static func cursorImage(_ color: NSColor, scale: CGFloat) -> CGImage? {
        let w = 18, h = 24
        guard let ctx = CGContext(data: nil, width: Int(CGFloat(w) * scale), height: Int(CGFloat(h) * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Drawn top-down.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let p = CGMutablePath()
        let pts: [CGPoint] = [(2, 2), (2, 18.5), (6.2, 14.6), (9.1, 21), (11.6, 19.9), (8.8, 13.6), (14.4, 13.6)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        p.addLines(between: pts)
        p.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(p)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(p)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        return ctx.makeImage()
    }

    // MARK: Geometry

    /// Window coordinates to the overlay's, which run from the top-left.
    private func toOverlay(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
    }

    private func toOverlay(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: window.frame.height - p.y) }

    private func spawnPoint() -> CGPoint {
        let button = MagicAnchors.rect("magicButton").map { toOverlay($0) }
        if fromMouse {
            let m = toOverlay(window.mouseLocationOutsideOfEventStream)
            if CGRect(origin: .zero, size: window.frame.size).contains(m) { return m }
        }
        if let button { return CGPoint(x: button.midX, y: button.midY) }
        return CGPoint(x: window.frame.width - 140, y: 26)
    }

    private func clipRect(_ c: Clip) -> CGRect? {
        canvas.magicWindowRect(of: c, in: model.project).map { toOverlay($0) }
    }

    /// A clip as it is now, or as it will be dropped if it isn't on the timeline yet.
    private func clip(_ id: UUID) -> Clip? { model.project.clip(id) ?? staged[id] }

    private func clipRect(_ id: UUID) -> CGRect? {
        clip(id).flatMap { clipRect($0) }
    }

    private var inspectorRect: CGRect {
        MagicAnchors.rect("inspector").map { toOverlay($0) }
            ?? CGRect(x: window.frame.width - 320, y: 52, width: 320, height: max(300, timelineRect.minY - 60))
    }

    private var timelineRect: CGRect { toOverlay(canvas.convert(canvas.bounds, to: nil)) }

    private func tileRect(_ asset: UUID) -> CGRect {
        let library = MagicAnchors.rect("library").map { toOverlay($0) } ?? CGRect(x: 0, y: 80, width: 250, height: 400)
        guard var r = MagicAnchors.rect(asset.uuidString).map({ toOverlay($0) }) else {
            return CGRect(x: library.minX + 16, y: library.minY + 90, width: 64, height: 36)
        }
        // Scrolled out of sight: come from the nearest edge of the list.
        r.origin.y = min(max(r.minY, library.minY + 80), library.maxY - r.height - 8)
        return r
    }

    private func cardFrame(_ c: Card) -> CGRect {
        if let f = c.frame { return f }
        // Its place in the inspector's stack.
        let insp = inspectorRect
        let f = CGRect(x: insp.minX + 12, y: insp.minY + 52 + CGFloat(c.row) * (cardSize.height + Self.cardGap),
                       width: cardSize.width, height: cardSize.height)
        c.frame = f
        return f
    }

    /// Where a cursor picks up and lets go for an edit, worked out when it sets off.
    private func points(_ i: Int, cache: Bool = true) -> (CGPoint, CGPoint) {
        if let g = slots[i].grab, let r = slots[i].release { return (g, r) }
        let (grab, release) = computePoints(slots[i].edit)
        if cache {
            slots[i].grab = grab
            slots[i].release = release
        }
        return (grab, release)
    }

    private func computePoints(_ edit: MagicEdit) -> (CGPoint, CGPoint) {
        let tl = timelineRect
        var grab = CGPoint(x: tl.midX, y: tl.midY), release = grab
        let project = model.project
        func x(_ t: Double) -> CGFloat { toOverlay(NSPoint(x: canvas.magicWindowX(t), y: 0)).x }
        switch edit {
        case .place(let clips, let asset):
            let tile = tileRect(asset)
            grab = CGPoint(x: tile.midX, y: tile.midY)
            if let c = clips.first, let r = clipRect(c) {
                release = CGPoint(x: r.minX + min(r.width, 260) * 0.3, y: r.midY)
            }
        case .trimHead(let ids, let from, let to), .trimTail(let ids, let from, let to):
            if let id = ids.first, let r = clipRect(id) {
                grab = CGPoint(x: x(from), y: r.midY)
                release = CGPoint(x: x(to), y: r.midY)
            }
        case .move(let ids, let from, let to, let tracks):
            if let id = ids.first, let c = clip(id), let r = clipRect(c) {
                var moved = c
                moved.start = to
                if let t = tracks[id] { moved.trackID = t }
                let dx = x(c.start + c.duration / 2) - x(from + c.duration / 2)
                grab = CGPoint(x: r.midX - dx, y: r.midY)
                if let r2 = clipRect(moved) { release = CGPoint(x: r2.midX, y: r2.midY) }
            }
        case .gain(let id, let from, let to):
            if let r = clipRect(id) {
                let px = r.minX + min(r.width * 0.5, 70)
                grab = CGPoint(x: px, y: r.minY + TimelineCanvas.magicGainNorm(from) * r.height)
                release = CGPoint(x: px, y: r.minY + TimelineCanvas.magicGainNorm(to) * r.height)
            }
        case .fadeIn(let id, let to):
            if let r = clipRect(id), let c = clip(id) {
                grab = CGPoint(x: r.minX + 6, y: r.minY + 8)
                release = CGPoint(x: max(r.minX + 6, x(c.start + to)), y: r.minY + 8)
            }
        case .fadeOut(let id, let to):
            if let r = clipRect(id), let c = clip(id) {
                grab = CGPoint(x: r.maxX - 6, y: r.minY + 8)
                release = CGPoint(x: min(r.maxX - 6, x(c.end - to)), y: r.minY + 8)
            }
        case .look(let id, _):
            if let card = cards[id] {
                let f = cardFrame(card)
                grab = CGPoint(x: f.minX + 119, y: f.minY + 35)
                release = grab
            } else if let r = finalRect(id) {
                grab = CGPoint(x: r.midX, y: tl.minY - 160)
                release = grab
            }
        case .grade(let id, let key, let to):
            if let card = cards[id] {
                let f = cardFrame(card)
                let y = f.minY + Self.rowY(MagicGradeKey.allCases.firstIndex(of: key) ?? 0)
                grab = CGPoint(x: f.minX + knobX(key, key.value(project.clip(id)?.grade)), y: y)
                release = CGPoint(x: f.minX + knobX(key, to), y: y)
            } else if let r = finalRect(id) {
                grab = CGPoint(x: r.midX, y: tl.minY - 160)
                release = grab
            }
        case .transition(let id, _):
            if let c = clip(id), let r = clipRect(c) {
                grab = CGPoint(x: r.minX, y: r.midY)
                release = grab
            }
        }
        return (grab, release)
    }

    private func finalRect(_ id: UUID) -> CGRect? {
        finalProject.clip(id).flatMap { canvas.magicWindowRect(of: $0, in: finalProject) }.map { toOverlay($0) }
    }

    // MARK: Frames

    private var now: Double { (CACurrentMediaTime() - t0) / pace + skip }

    private func fastForward() {
        let t = now
        if t < workEnd {
            skip += workEnd - t
            // Everyone heads home together.
            for a in agents where a.home > workEnd { a.home = workEnd + 0.02; a.gone = a.home + Self.homeTrip }
            showEnd = workEnd + Self.homeTrip + 0.1
        }
    }

    private var overlayFrame = NSRect.zero
    @objc private func step() {
        let t = now
        // Follow the window if it moves or resizes.
        if window.frame != overlayFrame {
            overlayFrame = window.frame
            overlay.setFrame(window.frame, display: false)
        }

        // The project at this moment: every edit applied as far as it has got.
        var p = plan.base
        var finished = 0
        for i in order where t >= slots[i].start {
            let s = slots[i]
            if t >= s.end { finished += 1 }
            // A clip's grade changes once its whole card is done: each new grade means re-grading its thumbnails.
            if s.edit.isGradeCard { continue }
            s.edit.apply(&p, (t - s.start) / (s.end - s.start))
        }
        for c in cards.values where t >= c.vanish - 0.1 {
            for i in c.slots { slots[i].edit.apply(&p, 1) }
        }
        model.live(autoCommit: false) { $0 = p }
        flashViewer(t)
        let wall = CACurrentMediaTime()
        if frames > 0 { longestFrame = max(longestFrame, wall - lastFrame) }
        lastFrame = wall
        frames += 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawAgents(t)
        drawCards(t)
        drawStatus(t, finished: finished)
        CATransaction.commit()

        if t >= showEnd { finish() }
    }

    private func drawAgents(_ t: Double) {
        for a in agents {
            guard !a.slots.isEmpty, t >= a.birth, t < a.gone else {
                a.cursor.isHidden = true
                a.tag.isHidden = true
                a.ghost.isHidden = true
                continue
            }
            let work = min(t, a.home)
            let pop = MagicEase.out((t - a.birth) / 0.12)
            let out = t > a.home ? MagicEase.inOut(min(1, (t - a.home) / Self.homeTrip)) : 0
            let dir = CGPoint(x: cos(a.angle), y: sin(a.angle))
            let start = spawn
            var pos = start
            var label = ""
            var ghost: (CGRect, CGImage?)?
            var pressed = false

            // The edit this cursor is on: the first it hasn't finished, or its last.
            if let k = a.slots.firstIndex(where: { slots[$0].end > work }) ?? (a.slots.isEmpty ? nil : a.slots.count - 1) {
                let i = a.slots[k]
                let s = slots[i]
                // A cursor's first trip starts the moment it leaves the button.
                let prevEnd = k > 0 ? slots[a.slots[k - 1]].end : s.travelStart - 0.03
                let prev = k > 0 ? points(a.slots[k - 1]).1 : start
                let leave = max(prevEnd + 0.03, k > 0 ? prevEnd + 0.03 : s.travelStart)
                let approach = 0.14
                if work >= s.end {
                    pos = points(i).1
                    if work - s.end < 0.12 { label = s.edit.label }
                } else if work < leave {
                    pos = prev
                } else if work < s.start - approach, s.start - leave > s.start - s.travelStart + 0.3 {
                    // Early: head over, then wait just off the control.
                    let hover = hoverPoint(i, a)
                    if work < leave + 0.3 {
                        let u = MagicEase.inOut((work - leave) / 0.3)
                        pos = Self.bezier(prev, travelControl(prev, hover, a, first: k == 0, dir: dir), hover, CGFloat(u))
                    } else {
                        let w = work * 6 + a.angle * 3
                        pos = CGPoint(x: hover.x + CGFloat(sin(w)) * 3, y: hover.y + CGFloat(cos(w * 0.8)) * 3)
                    }
                    label = s.edit.label
                } else if work < s.start {
                    let (grab, _) = points(i)
                    let early = s.start - leave > s.start - s.travelStart + 0.3
                    let from = early ? hoverPoint(i, a) : prev
                    // Otherwise it sets off when it needs to, at its own pace.
                    let t0 = early ? s.start - approach : max(leave, s.travelStart)
                    let u = MagicEase.inOut((work - t0) / max(0.01, s.start - t0))
                    pos = Self.bezier(from, early ? CGPoint(x: (from.x + grab.x) / 2, y: (from.y + grab.y) / 2)
                                      : travelControl(from, grab, a, first: k == 0, dir: dir), grab, CGFloat(u))
                    label = s.edit.label
                } else {
                    let (grab, release) = points(i)
                    let u = CGFloat(MagicEase.inOut((work - s.start) / (s.end - s.start)))
                    pos = CGPoint(x: grab.x + (release.x - grab.x) * u, y: grab.y + (release.y - grab.y) * u)
                    label = s.edit.label
                    pressed = true
                    if case .place(let clips, let asset) = s.edit {
                        let tile = tileRect(asset)
                        let target = clips.first.flatMap { clipRect($0) } ?? tile
                        let w0 = tile.width, h0 = tile.height
                        let w1 = min(target.width, 260), h1 = target.height
                        let w = w0 + (w1 - w0) * u, h = h0 + (h1 - h0) * u
                        let poster = model.media.posters[asset]?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        ghost = (CGRect(x: pos.x - w * 0.3, y: pos.y - h / 2, width: w, height: h), poster)
                    }
                }
            }
            if out > 0 {
                // Back into the button.
                let ctrl = CGPoint(x: (pos.x + spawn.x) / 2 + dir.x * 120, y: (pos.y + spawn.y) / 2 + dir.y * 120)
                pos = Self.bezier(pos, ctrl, spawn, CGFloat(out))
                label = ""
            }

            a.cursor.isHidden = false
            a.cursor.position = pos
            let fade = out > 0.6 ? (1 - out) / 0.4 : 1
            a.cursor.opacity = Float(min(1, pop * 2) * fade)
            let scale = (0.45 + 0.55 * pop) * (1 - 0.5 * out) * (pressed ? 0.88 : 1)
            a.cursor.transform = CATransform3DMakeScale(scale, scale, 1)

            if label.isEmpty {
                a.tag.isHidden = true
            } else {
                if label != a.label {
                    a.label = label
                    a.tagText.string = label
                    let w = ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width) + 12
                    a.tag.bounds = CGRect(x: 0, y: 0, width: w, height: 16)
                    a.tagText.frame = CGRect(x: 0, y: 1.5, width: w, height: 14)
                }
                a.tag.isHidden = false
                a.tag.position = CGPoint(x: pos.x + 10 + a.tag.bounds.width / 2, y: pos.y + 26)
                a.tag.opacity = a.cursor.opacity
            }

            if let (frame, poster) = ghost {
                a.ghost.isHidden = false
                a.ghost.frame = frame
                if a.ghost.contents == nil {
                    if let poster { a.ghost.contents = poster } else { a.ghost.backgroundColor = a.color.withAlphaComponent(0.3).cgColor }
                }
                a.ghost.opacity = 0.9
            } else if !a.ghost.isHidden {
                a.ghost.isHidden = true
                a.ghost.contents = nil
                a.ghost.backgroundColor = nil
            }
        }
    }

    private func drawCards(_ t: Double) {
        let project = model.project
        drawBackdrop(t)
        for c in cards.values {
            guard t >= c.appear, t < c.vanish + 0.16 else {
                c.layer.opacity = 0
                continue
            }
            let f = cardFrame(c)
            let target = CGPoint(x: f.midX, y: f.midY)
            if t < c.appear + 0.16 {
                // Slides into its place in the inspector.
                let u = CGFloat(MagicEase.out((t - c.appear) / 0.16))
                c.layer.position = CGPoint(x: target.x + 40 * (1 - u), y: target.y)
                c.layer.transform = CATransform3DIdentity
                c.layer.opacity = Float(u)
            } else if t > c.vanish {
                // Done: shrinks away down onto its clip.
                let u = CGFloat(MagicEase.inOut((t - c.vanish) / 0.16))
                let clip = clipRect(c.clip).map { CGPoint(x: $0.midX, y: $0.midY) } ?? target
                c.layer.position = CGPoint(x: target.x + (clip.x - target.x) * u, y: target.y + (clip.y - target.y) * u)
                let s = 1 - 0.7 * u
                c.layer.transform = CATransform3DMakeScale(s, s, 1)
                c.layer.opacity = Float(1 - u)
            } else {
                c.layer.position = target
                c.layer.transform = CATransform3DIdentity
                c.layer.opacity = 1
            }

            // Controls follow the cursors dragging them.
            let grade = project.clip(c.clip)?.grade
            for i in c.slots {
                let s = slots[i]
                let u = t < s.start ? 0 : MagicEase.inOut(min(1, (t - s.start) / (s.end - s.start)))
                switch s.edit {
                case .look(_, let name):
                    let picked = t >= s.end
                    c.chipText.string = picked ? name : "None"
                    c.chipText.foregroundColor = (picked ? Theme.NS.text : Theme.NS.textDim).cgColor
                    c.chip.borderColor = (t >= s.start && t < s.end + 0.1 ? NSColor.white.withAlphaComponent(0.5) : NSColor(white: 1, alpha: 0.08)).cgColor
                case .grade(_, let key, let to):
                    guard let k = c.knobs[key] else { continue }
                    let from = t >= s.end ? key.value(grade) : 0
                    let v = t >= s.end ? from : to * u
                    let x = knobX(key, v), mid = knobX(key, 0)
                    let y = Self.rowY(MagicGradeKey.allCases.firstIndex(of: key) ?? 0)
                    k.knob.position = CGPoint(x: x, y: y)
                    k.fill.frame = CGRect(x: min(x, mid), y: y - 1, width: abs(x - mid), height: 2)
                    k.value.string = key == .exposure ? String(format: "%+.2f", v) : String(format: "%+.0f", v)
                    k.value.foregroundColor = (abs(v) > 0.001 ? Theme.NS.text : Theme.NS.textFaint).cgColor
                default: break
                }
            }
        }
    }

    /// The viewer shows the shots as they're picked, one after another.
    private func flashViewer(_ t: Double) {
        let preview = model.sourcePreview
        // Not too often: each is a full-size frame for the viewer, and they cost smoothness.
        guard t < workEnd, t - lastFlash > 0.3 else { return }
        // Step through the shots already on the timeline, in order.
        let shots = model.project.clips.filter { $0.kind == .video }.sorted { ($0.start, $0.trackID.uuidString) < ($1.start, $1.trackID.uuidString) }
        guard !shots.isEmpty else { return }
        flashIndex = (flashIndex + 1) % shots.count
        let c = shots[flashIndex]
        guard let a = model.project.asset(c.assetID) else { return }
        lastFlash = t
        let time = c.sourceStart + c.duration * 0.6
        // Swapped in only once the frame has arrived, so the viewer never goes black.
        model.media.viewerFrame(asset: a.id, time: time) { [weak self] img in
            guard let self, !self.done else { return }
            preview.show(a, at: time, image: img)
        }
    }

    /// Covers the real inspector while grade panels are stacked in it.
    private func drawBackdrop(_ t: Double) {
        let (a, b) = backdropSpan
        let u = t < a ? 0 : t < a + 0.15 ? (t - a) / 0.15 : t < b ? 1 : max(0, 1 - (t - b) / 0.15)
        backdrop.opacity = Float(u)
        guard u > 0 else { return }
        backdrop.frame = inspectorRect
        let active = cards.values.filter { t >= $0.appear && t < $0.vanish }.count
        backdropCount.string = active == 0 ? "" : "\(active) clip\(active == 1 ? "" : "s")"
    }

    private func drawStatus(_ t: Double, finished: Int) {
        let out = agents.filter { !$0.slots.isEmpty && t >= $0.birth && t < $0.gone }.count
        let text = "✦  \(out) agent\(out == 1 ? "" : "s")  ·  \(finished) / \(slots.count) edits"
        statusText.string = text
        let w = ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).width) + 28
        let tl = timelineRect
        status.bounds = CGRect(x: 0, y: 0, width: w, height: 26)
        status.position = CGPoint(x: tl.midX, y: tl.minY - 22)
        statusText.frame = CGRect(x: 0, y: 6, width: w, height: 15)
        let fadeIn = min(1, t / 0.2)
        let fadeOut = t > showEnd - Self.outro ? 1 - min(1, (t - (showEnd - Self.outro)) / Self.outro) : 1
        status.opacity = Float(fadeIn * fadeOut)
    }

    /// A gentle curve between two points; the first trip fans out from where the cursors appeared.
    private func travelControl(_ a: CGPoint, _ b: CGPoint, _ agent: Agent, first: Bool, dir: CGPoint) -> CGPoint {
        if first {
            // Swings out of the button toward its target, curving one way or the other.
            let dx = b.x - a.x, dy = b.y - a.y
            let turn = (agent.angle > .pi ? 0.6 : -0.6) * (0.6 + 0.4 * sin(agent.angle * 3))
            return CGPoint(x: a.x + (dx * cos(turn) - dy * sin(turn)) * 0.45, y: a.y + (dx * sin(turn) + dy * cos(turn)) * 0.45)
        }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let bend: CGFloat = agent.angle.truncatingRemainder(dividingBy: 0.7) > 0.35 ? 0.16 : -0.16
        return CGPoint(x: mid.x - (b.y - a.y) * bend, y: mid.y + (b.x - a.x) * bend)
    }

    private func hoverPoint(_ i: Int, _ agent: Agent) -> CGPoint {
        if let h = slots[i].hover { return h }
        let g = points(i, cache: false).0
        let h = CGPoint(x: g.x + CGFloat(cos(agent.angle)) * 28, y: g.y - 22 + CGFloat(sin(agent.angle)) * 12)
        slots[i].hover = h
        return h
    }

    private static func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint {
        let v = 1 - u
        return CGPoint(x: v * v * a.x + 2 * v * u * c.x + u * u * b.x, y: v * v * a.y + 2 * v * u * c.y + u * u * b.y)
    }

    // MARK: End

    private func finish() {
        guard !done else { return }
        done = true
        link?.invalidate()
        link = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        var p = plan.base
        for i in order { slots[i].edit.apply(&p, 1) }
        model.live(autoCommit: false) { $0 = p }
        model.commitLive()
        model.sourcePreview.clear()
        if CommandLine.arguments.contains("--magic") {
            FileHandle.standardError.write(String(format: "MAGIC agents %d edits %d work %.2fs frames %d longest %.0fms\n",
                         agents.count, slots.count, workEnd, frames, longestFrame * 1000).data(using: .utf8)!)
        }
        window.removeChildWindow(overlay)
        overlay.orderOut(nil)
        model.rebuildSuspended = false
        model.seek(to: 0)
        Self.current = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [model] in model.play() }
        // `--magic-undo` (testing): check one undo takes the whole cut away.
        if CommandLine.arguments.contains("--magic-undo") {
            let built = model.project.clips.count
            model.undo()
            FileHandle.standardError.write("MAGIC UNDO built \(built) clips, after undo \(model.project.clips.count)\n".data(using: .utf8)!)
        }
    }
}
