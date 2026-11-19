import AppKit
import QuartzCore

/// The show while Magic works out an edit, before the swarm makes it, in the swarm's own plain style.
/// Cursors come out of the Magic button and then, following what's really happening:
/// - scout: fly to clips and sweep a scan across each one they "watch";
/// - think: circle the viewer with typing dots in their name tags, over a dot field (drifting noise,
///   brightest under each cursor);
/// - plan: sketch the clips of the coming edit as dashed ghosts on the timeline;
/// then go back into the button, and the swarm takes over. Nothing on the timeline moves.
@MainActor
final class MagicThinking: NSObject {
    static private(set) var current: MagicThinking?

    enum Phase { case scout, think, plan, leaving }

    private final class Cursor {
        let body = CALayer()
        let tag = CALayer()
        let name = CATextLayer()
        let dots = [CALayer(), CALayer(), CALayer()]
        var pos: CGPoint
        var vel = CGPoint.zero
        var target: CGPoint
        /// Scouting: the rect it's sweeping, and until when.
        var watching: CGRect?
        var watchUntil = 0.0
        var watchStart = 0.0
        /// Planning: the ghost it's drawing.
        var ghost: Int?
        var seed: Double
        var born: Double
        init(at p: CGPoint, seed: Double, born: Double) { pos = p; target = p; self.seed = seed; self.born = born }
    }

    private final class Ghost {
        let rect: CGRect
        let shape = CAShapeLayer()
        let fill = CALayer()
        var progress = 0.0
        var done = false
        init(_ r: CGRect) { rect = r }
    }

    private weak var host: NSWindow?
    private weak var model: EditorModel?
    private let overlay: NSWindow
    private let root = CALayer()
    private let field = DotField()
    private let scanLayer = CALayer()
    private var scans: [ObjectIdentifier: (box: CALayer, bar: CALayer)] = [:]
    private var cursors: [Cursor] = []
    private var ghosts: [Ghost] = []
    private var ghostKeys: [String] = []
    private var link: CADisplayLink?
    private var t0 = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private(set) var phase: Phase = .scout
    private var phaseSince = 0.0
    private var targets: [CGRect] = []
    private var focusQueue: [CGRect] = []
    private var fieldAlpha = 0.0
    private let color: NSColor
    private let label: String
    private var leaveDone: (() -> Void)?
    private var lastEvent = CACurrentMediaTime()

    // MARK: Starting and ending

    /// Starts the show over the editor window, or returns nil when there isn't one on screen.
    static func begin(model: EditorModel, name: String, color: NSColor, count: Int = 7) -> MagicThinking? {
        current?.cancel()
        guard let window = TimelineCanvas.current?.window, window.isVisible else { return nil }
        let t = MagicThinking(window: window, model: model, name: name, color: color, count: count)
        current = t
        return t
    }

    private init(window: NSWindow, model: EditorModel, name: String, color: NSColor, count: Int) {
        host = window
        self.model = model
        self.color = color
        label = name
        overlay = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        let view = FlippedHost(frame: NSRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        view.layer?.addSublayer(root)
        root.frame = view.bounds
        root.addSublayer(field)
        root.addSublayer(scanLayer)
        overlay.contentView = view
        window.addChildWindow(overlay, ordered: .above)

        let scale = window.backingScaleFactor
        field.contentsScale = scale
        field.opacity = 0
        let start = buttonPoint
        let image = MagicShow.cursorImage(color, scale: scale)
        // A light colour (Local's white) gets a dark, see-through tag so its white text and dots read.
        let light = (color.usingColorSpace(.sRGB).map { 0.3 * $0.redComponent + 0.59 * $0.greenComponent + 0.11 * $0.blueComponent } ?? 0) > 0.7
        let tagColor = light ? NSColor.black.withAlphaComponent(0.62).cgColor : (color.blended(withFraction: 0.18, of: .black) ?? color).cgColor
        for i in 0..<count {
            let c = Cursor(at: start, seed: Double(i) * 1.37 + Double.random(in: 0...1), born: Double(i) * 0.09)
            c.body.contents = image
            c.body.contentsScale = scale
            c.body.bounds = CGRect(x: 0, y: 0, width: 18, height: 24)
            c.body.anchorPoint = CGPoint(x: 2 / 18, y: 2 / 24)
            c.tag.backgroundColor = tagColor
            c.tag.cornerRadius = 4
            c.tag.bounds = CGRect(x: 0, y: 0, width: 40, height: 16)
            c.tag.anchorPoint = .zero
            c.name.string = name
            c.name.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            c.name.fontSize = 10
            c.name.foregroundColor = NSColor.white.cgColor
            c.name.alignmentMode = .center
            c.name.contentsScale = scale
            for d in c.dots {
                d.backgroundColor = NSColor.white.cgColor
                d.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
                d.cornerRadius = 2
                c.tag.addSublayer(d)
            }
            c.tag.addSublayer(c.name)
            root.addSublayer(c.tag)
            root.addSublayer(c.body)
            c.body.opacity = 0
            c.tag.opacity = 0
            cursors.append(c)
        }
        let nameWidth = ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width) + 14
        for c in cursors { c.tag.bounds.size.width = nameWidth }
        startLoop()
        scout(assets: nil)
    }

    /// Ends the show: everything carries on as it was and fades out where it is, then `done` (where the
    /// swarm starts).
    func end(then done: (() -> Void)? = nil) {
        guard leaveDone == nil, fadeFrom == nil else { return }
        fadeFrom = now
        leaveDone = done
    }

    /// When the fade-out began.
    private var fadeFrom: Double?
    private static let fadeTime = 0.6

    /// Takes the show down at once.
    func cancel() {
        link?.invalidate()
        link = nil
        host?.removeChildWindow(overlay)
        overlay.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    // MARK: What's happening

    /// Scouting: the clips of these library items (all of them when nil), on the timeline and in the Media panel.
    func scout(assets: Set<UUID>?) {
        lastEvent = CACurrentMediaTime()
        guard phase != .leaving else { return }
        if phase != .scout { phase = .scout; phaseSince = now }
        guard let model else { return }
        var rects: [CGRect] = []
        for a in model.project.assets where assets?.contains(a.id) ?? true {
            if let r = MagicAnchors.rect(a.id.uuidString).map(toOverlay) { rects.append(r) }
        }
        if let canvas = TimelineCanvas.current {
            for c in model.project.clips where (c.kind == .video || c.kind == .image) && (assets?.contains(c.assetID ?? UUID()) ?? true) {
                if let r = canvas.magicWindowRect(of: c, in: model.project).map(toOverlay) { rects.append(r) }
            }
        }
        targets = rects.filter { $0.width > 6 && $0.height > 6 }
    }

    /// One library item is being looked at: a cursor goes straight to it.
    func focus(asset: UUID) {
        lastEvent = CACurrentMediaTime()
        guard phase != .leaving else { return }
        if phase != .scout { phase = .scout; phaseSince = now }
        if let r = MagicAnchors.rect(asset.uuidString).map(toOverlay) { focusQueue.append(r) }
        if let model, let canvas = TimelineCanvas.current {
            for c in model.project.clips where c.assetID == asset {
                if let r = canvas.magicWindowRect(of: c, in: model.project).map(toOverlay) { focusQueue.append(r); break }
            }
        }
    }

    func think() {
        guard phase != .leaving, phase != .think else { return }
        phase = .think
        phaseSince = now
        for c in cursors { c.watching = nil }
    }

    /// Planning: the clips of the coming edit, sketched as ghosts on the timeline.
    func plan(_ project: Project) {
        lastEvent = CACurrentMediaTime()
        guard phase != .leaving, let canvas = TimelineCanvas.current else { return }
        if phase != .plan { phase = .plan; phaseSince = now; for c in cursors { c.watching = nil } }
        let clips = project.clips.filter { $0.kind != .audio || $0.linkID == nil }
        for c in clips {
            let key = "\(c.trackID)|\(Int(c.start * 100))|\(Int(c.duration * 100))"
            guard !ghostKeys.contains(key), let r = canvas.magicWindowRect(of: c, in: project).map(toOverlay),
                  r.width > 3 else { continue }
            ghostKeys.append(key)
            let g = Ghost(r.insetBy(dx: 1, dy: 3))
            let path = CGPath(roundedRect: CGRect(origin: .zero, size: g.rect.size), cornerWidth: 6, cornerHeight: 6, transform: nil)
            g.shape.path = path
            g.shape.frame = g.rect
            g.shape.fillColor = nil
            g.shape.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
            g.shape.lineWidth = 1.5
            g.shape.lineDashPattern = [7, 6]
            g.shape.strokeEnd = 0
            g.fill.frame = g.rect
            g.fill.cornerRadius = 6
            g.fill.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            g.fill.opacity = 0
            root.insertSublayer(g.fill, below: scanLayer)
            root.insertSublayer(g.shape, below: scanLayer)
            ghosts.append(g)
        }
    }

    // MARK: The loop

    private var now: Double { CACurrentMediaTime() - t0 }

    private func startLoop() {
        let l = overlay.contentView!.displayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private var buttonPoint: CGPoint {
        if let r = MagicAnchors.rect("magicButton").map(toOverlay) { return CGPoint(x: r.midX, y: r.midY) }
        return CGPoint(x: (host?.frame.width ?? 800) - 140, y: 26)
    }

    private var timelineRect: CGRect {
        TimelineCanvas.current.map { toOverlay($0.convert($0.bounds, to: nil)) } ?? CGRect(x: 200, y: 500, width: 900, height: 200)
    }

    private var viewerRect: CGRect {
        MagicAnchors.rect("viewer").map(toOverlay)
            ?? CGRect(x: 300, y: 80, width: max(200, (host?.frame.width ?? 1200) - 640), height: 360)
    }

    @objc private func step() {
        guard let host else { return cancel() }
        if overlay.frame != host.frame {
            overlay.setFrame(host.frame, display: false)
            root.frame = CGRect(origin: .zero, size: host.frame.size)
        }
        let wall = CACurrentMediaTime()
        let dt = min(1.0 / 30, max(1.0 / 240, wall - last))
        last = wall
        let t = now
        // A while with nothing new from the AI: it's thinking.
        if phase != .leaving, phase != .think, wall - lastEvent > 2.5, focusQueue.isEmpty { think() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let view = viewerRect
        let center = CGPoint(x: view.midX, y: view.midY)
        for (i, c) in cursors.enumerated() {
            let alive = t >= c.born
            if !alive { continue }
            // Where to go.
            switch phase {
            case .scout:
                if c.watching == nil || t > c.watchUntil {
                    if !focusQueue.isEmpty {
                        c.watching = focusQueue.removeFirst()
                    } else if !targets.isEmpty {
                        c.watching = targets[Int.random(in: 0..<targets.count)]
                    } else {
                        c.watching = view.insetBy(dx: view.width * 0.3, dy: view.height * 0.3)
                    }
                    c.watchStart = t
                    c.watchUntil = t + Double.random(in: 1.2...2.2)
                }
                if let r = c.watching { c.target = CGPoint(x: r.minX + r.width * 0.55, y: r.midY + 4) }
            case .think:
                let ang = t * 0.42 + Double(i) / Double(cursors.count) * .pi * 2
                let wobble = 1 + 0.08 * sin(t * 1.6 + c.seed)
                c.target = CGPoint(x: center.x + cos(ang) * view.width * 0.36 * wobble,
                                   y: center.y + sin(ang) * view.height * 0.36 * wobble)
            case .plan:
                if c.ghost == nil || ghosts[c.ghost!].done {
                    c.ghost = ghosts.indices.first { k in !ghosts[k].done && !cursors.contains { $0 !== c && $0.ghost == k } }
                }
                if let k = c.ghost {
                    let g = ghosts[k]
                    let distance = hypot(c.pos.x - (g.rect.minX + g.rect.width * g.progress), c.pos.y - g.rect.minY)
                    if distance < 30 {
                        g.progress = min(1, g.progress + dt * (220 / max(60, g.rect.width + g.rect.height)))
                        g.shape.strokeEnd = g.progress
                        if g.progress >= 1, !g.done { g.done = true }
                    }
                    let p = g.progress
                    // Along the top, then down the right side.
                    c.target = p < 0.8
                        ? CGPoint(x: g.rect.minX + g.rect.width * min(1, p / 0.8), y: g.rect.minY)
                        : CGPoint(x: g.rect.maxX, y: g.rect.minY + g.rect.height * (p - 0.8) / 0.2)
                } else {
                    // Nothing left to sketch: drift over the timeline, admiring the plan.
                    let tl = timelineRect
                    let ang = t * 0.5 + c.seed * 2
                    c.target = CGPoint(x: tl.midX + cos(ang) * tl.width * 0.32, y: tl.minY + tl.height * 0.4 + sin(ang * 1.3) * tl.height * 0.18)
                }
            case .leaving:
                break
            }

            // Smooth easing towards where it's going, no overshoot, like the swarm's cursors.
            let rate: CGFloat = phase == .leaving ? 9 : phase == .think ? 4 : 5
            let follow = 1 - exp(-rate * CGFloat(dt))
            let before = c.pos
            c.pos.x += (c.target.x - c.pos.x) * follow
            c.pos.y += (c.target.y - c.pos.y) * follow
            c.vel = CGPoint(x: (c.pos.x - before.x) / CGFloat(dt), y: (c.pos.y - before.y) / CGFloat(dt))

            let fading = fadeFrom.map { max(0, 1 - (t - $0) / Self.fadeTime) } ?? 1
            let appear = min(1, (t - c.born) / 0.18) * fading
            c.body.position = c.pos
            let opacity = Float(appear)
            c.body.opacity = opacity
            c.tag.opacity = opacity
            c.tag.position = CGPoint(x: c.pos.x + 10, y: c.pos.y + 20)
            // The tag: the name, or typing dots while thinking.
            let typing = phase == .think
            c.name.opacity = typing ? 0 : 1
            c.name.frame = CGRect(x: 0, y: 1.5, width: c.tag.bounds.width, height: 14)
            for (d, dot) in c.dots.enumerated() {
                let b = 0.5 + 0.5 * sin(t * 6 - Double(d) * 0.9 + c.seed)
                dot.opacity = typing ? Float(0.35 + 0.65 * b) : 0
                dot.position = CGPoint(x: c.tag.bounds.width / 2 - 8 + CGFloat(d) * 8, y: 8 - CGFloat(b) * 1.6)
            }
        }
        updateScans(t)
        updateField(t, view: view, dt: dt)
        updateGhosts(t)
        CATransaction.commit()

        let fade = fadeFrom.map { max(0, 1 - (now - $0) / Self.fadeTime) } ?? 1
        scanLayer.opacity = Float(fade)
        for g in ghosts { g.shape.opacity = Float(fade); if fade < 1 { g.fill.opacity = Float(fade) * g.fill.opacity } }
        if let f = fadeFrom, now - f >= Self.fadeTime {
            let done = leaveDone
            leaveDone = nil
            cancel()
            done?()
        }
    }

    // MARK: Pieces

    private func updateScans(_ t: Double) {
        var seen = Set<ObjectIdentifier>()
        for c in cursors {
            let key = ObjectIdentifier(c)
            guard phase == .scout, let r = c.watching, hypot(c.pos.x - (r.minX + r.width * 0.55), c.pos.y - (r.midY + 4)) < 40 else { continue }
            seen.insert(key)
            let s = scans[key] ?? {
                let box = CALayer()
                box.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
                box.borderWidth = 1.5
                box.cornerRadius = 5
                box.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
                box.masksToBounds = true
                let bar = CALayer()
                bar.backgroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
                box.addSublayer(bar)
                scanLayer.addSublayer(box)
                return (box, bar)
            }()
            scans[key] = s
            s.box.frame = r
            let u = ((t - c.watchStart) * 0.9).truncatingRemainder(dividingBy: 1)
            s.bar.frame = CGRect(x: r.width * CGFloat(u) - 1, y: 0, width: 2, height: r.height)
            s.box.opacity = Float(min(1, (t - c.watchStart) * 4))
        }
        for (key, s) in scans where !seen.contains(key) {
            s.box.removeFromSuperlayer()
            scans[key] = nil
        }
    }

    private func updateField(_ t: Double, view: CGRect, dt: Double) {
        let want = phase == .think ? 1.0 : 0.0
        fieldAlpha += (want - fieldAlpha) * min(1, dt * (want > fieldAlpha ? 1.2 : 3))
        field.frame = view
        field.opacity = Float(fieldAlpha * (fadeFrom.map { max(0, 1 - (now - $0) / Self.fadeTime) } ?? 1))
        guard fieldAlpha > 0.01 else { return }
        field.time = t
        field.tint = color
        field.glows = cursors.map { CGPoint(x: $0.pos.x - view.minX + 6, y: $0.pos.y - view.minY + 10) }
        field.setNeedsDisplay()
    }

    private func updateGhosts(_ t: Double) {
        for g in ghosts {
            g.shape.lineDashPhase = CGFloat(-t * 24)
            g.fill.opacity = g.done ? 1 : 0
        }
    }

    private func toOverlay(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: (host?.frame.height ?? 0) - r.maxY, width: r.width, height: r.height)
    }
}

/// The shimmering dots over the viewer while thinking: a drifting noise, brightest under the cursors.
private final class DotField: CALayer {
    var time = 0.0
    var glows: [CGPoint] = []
    var tint: NSColor = .white

    override init() { super.init(); needsDisplayOnBoundsChange = true; masksToBounds = true }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    private static func noise(_ a: Double, _ b: Double) -> Double {
        sin(a * 1.7 + sin(b * 1.3)) * 0.5 + sin(b * 2.1 - a * 0.6) * 0.3 + sin((a + b) * 0.9) * 0.2
    }

    override func draw(in ctx: CGContext) {
        let w = bounds.width, h = bounds.height
        guard w > 10, h > 10 else { return }
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
        }
        // Darken the picture a touch so the dots read.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.fill(bounds)
        // A fine grid of small dots.
        let spacing = max(6, min(w, h) / 55)
        let reach = Double(max(w, h)) * 0.13
        let warm = tint.blended(withFraction: 0.55, of: .white) ?? tint
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        warm.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        var y = spacing / 2
        while y < h {
            var x = spacing / 2
            while x < w {
                let u = Double(x / w), v = Double(y / h)
                let n = min(1, pow(Self.noise(u * 4 + time * 0.3, v * 3.2 - time * 0.22) * 0.5 + 0.5, 2.6) * 1.2) * 0.65
                var glow = 0.0
                for p in glows {
                    let d = hypot(Double(x - p.x), Double(y - p.y))
                    glow = max(glow, 1 - d / reach)
                }
                glow = pow(max(0, glow), 2) * 0.7
                let level = min(1, n + glow * (1 - n * 0.5))
                let radius = 0.35 + CGFloat(level) * spacing * 0.16
                ctx.setFillColor(red: r + (1 - r) * CGFloat(level) * 0.5, green: g + (1 - g) * CGFloat(level) * 0.4,
                                 blue: b + (1 - b) * CGFloat(level) * 0.3, alpha: 0.05 + 0.6 * CGFloat(level))
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
    }
}

private final class FlippedHost: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
