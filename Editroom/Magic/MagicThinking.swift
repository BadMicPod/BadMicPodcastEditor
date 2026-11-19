import AppKit
import QuartzCore

/// The show while Magic works out an edit, before the swarm makes it (Editing), in the swarm's own plain
/// style. Cursors come out of the Magic button and go through three stages, only ever forwards:
/// - Looking: they visit the items in the Media panel;
/// - Analyzing: they sweep a scan across the clips being studied, on the timeline and in Media;
/// - Thinking: they circle the viewer over a dot field (drifting noise, brightest under each cursor),
///   while the coming edit appears on the timeline as dashed ghost clips;
/// then they fade out where they are, and the swarm takes over. Nothing on the timeline moves.
@MainActor
final class MagicThinking: NSObject {
    static private(set) var current: MagicThinking?

    enum Stage: Int, Comparable {
        case looking, analyzing, thinking
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        var word: String {
            switch self {
            case .looking: "Looking"
            case .analyzing: "Analyzing"
            case .thinking: "Thinking"
            }
        }
    }

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
        /// Thinking: off to look at a clip for a moment, until then.
        var detourUntil = 0.0
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
        let born: Double
        init(_ r: CGRect, born: Double) { rect = r; self.born = born }
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
    private(set) var stage: Stage = .looking {
        didSet { MagicState.shared.stage = stage.word }
    }
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
            c.name.string = ""
            c.name.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            c.name.fontSize = 10
            c.name.foregroundColor = NSColor.white.cgColor
            c.name.alignmentMode = .left
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
        for c in cursors { c.tag.bounds.size.width = Self.tagWidth(stage.word) }
        MagicState.shared.stage = stage.word
        startLoop()
        look()
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
        if Self.current === self {
            Self.current = nil
            MagicState.shared.stage = nil
        }
    }

    // MARK: What's happening (stages only move forward)

    private func advance(to s: Stage) {
        lastEvent = CACurrentMediaTime()
        guard fadeFrom == nil, s > stage else { return }
        stage = s
        for c in cursors { c.watching = nil }
    }

    /// Looking: the items in the Media panel.
    func look() {
        lastEvent = CACurrentMediaTime()
        guard let model, stage == .looking else { return }
        targets = model.project.assets.compactMap { MagicAnchors.rect($0.id.uuidString).map(toOverlay) }.filter { $0.width > 6 }
    }

    /// Analyzing: these library items (all of them when nil), on the timeline and in the Media panel.
    func analyze(assets: Set<UUID>?) {
        advance(to: .analyzing)
        guard let model, stage == .analyzing else { return }
        var rects: [CGRect] = []
        if let canvas = TimelineCanvas.current {
            for c in model.project.clips where (c.kind == .video || c.kind == .image) && (assets?.contains(c.assetID ?? UUID()) ?? true) {
                if let r = canvas.magicWindowRect(of: c, in: model.project).map(toOverlay) { rects.append(r) }
            }
        }
        for a in model.project.assets where assets?.contains(a.id) ?? true {
            if let r = MagicAnchors.rect(a.id.uuidString).map(toOverlay) { rects.append(r) }
        }
        targets = rects.filter { $0.width > 6 && $0.height > 6 }
    }

    /// One library item is being looked at: a cursor goes straight to it (for a moment, if it's already
    /// thinking: the stage doesn't go back).
    func focus(asset: UUID) {
        if stage < .analyzing { analyze(assets: nil) }
        lastEvent = CACurrentMediaTime()
        guard fadeFrom == nil else { return }
        var rect = MagicAnchors.rect(asset.uuidString).map(toOverlay)
        if let model, let canvas = TimelineCanvas.current, let c = model.project.clips.first(where: { $0.assetID == asset }) {
            rect = canvas.magicWindowRect(of: c, in: model.project).map(toOverlay) ?? rect
        }
        guard let rect else { return }
        if stage == .thinking {
            if let c = cursors.min(by: { $0.detourUntil < $1.detourUntil }) {
                c.watching = rect
                c.watchStart = now
                c.detourUntil = now + 1.6
            }
        } else {
            focusQueue.append(rect)
        }
    }

    func think() { advance(to: .thinking) }

    /// The coming edit, sketched as dashed ghosts on the timeline as it takes shape (Thinking).
    func plan(_ project: Project) {
        advance(to: .thinking)
        guard fadeFrom == nil, let canvas = TimelineCanvas.current else { return }
        let clips = project.clips.filter { $0.kind != .audio || $0.linkID == nil }
        for c in clips {
            let key = "\(c.trackID)|\(Int(c.start * 100))|\(Int(c.duration * 100))"
            guard !ghostKeys.contains(key), let r = canvas.magicWindowRect(of: c, in: project).map(toOverlay),
                  r.width > 3 else { continue }
            ghostKeys.append(key)
            // One after another, a little apart.
            let g = Ghost(r.insetBy(dx: 1, dy: 3), born: max(now, (ghosts.last?.born ?? 0) + 0.12))
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
        // Analyzing, then a while with nothing new from the AI: it's thinking.
        if fadeFrom == nil, stage == .analyzing, wall - lastEvent > 2.5, focusQueue.isEmpty { think() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let view = viewerRect
        let center = CGPoint(x: view.midX, y: view.midY)
        for (i, c) in cursors.enumerated() {
            let alive = t >= c.born
            if !alive { continue }
            // Where to go.
            let detouring = stage == .thinking && t < c.detourUntil
            if stage < .thinking {
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
            } else if detouring, let r = c.watching {
                c.target = CGPoint(x: r.minX + r.width * 0.55, y: r.midY + 4)
            } else {
                if c.watching != nil, !detouring { c.watching = nil }
                let ang = t * 0.42 + Double(i) / Double(cursors.count) * .pi * 2
                let wobble = 1 + 0.08 * sin(t * 1.6 + c.seed)
                c.target = CGPoint(x: center.x + cos(ang) * view.width * 0.36 * wobble,
                                   y: center.y + sin(ang) * view.height * 0.36 * wobble)
            }

            // Smooth easing towards where it's going, no overshoot, like the swarm's cursors.
            let rate: CGFloat = stage == .thinking && !detouring ? 4 : 5
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
            // The tag says what they're doing, with typing dots after it.
            let word = stage.word
            if c.name.string as? String != word {
                c.name.string = word
                c.tag.bounds.size.width = Self.tagWidth(word)
            }
            let textWidth = Self.tagWidth(word) - 30
            c.name.frame = CGRect(x: 7, y: 1.5, width: textWidth, height: 14)
            for (d, dot) in c.dots.enumerated() {
                let b = 0.5 + 0.5 * sin(t * 6 - Double(d) * 0.9 + c.seed)
                dot.opacity = Float(0.35 + 0.65 * b)
                dot.position = CGPoint(x: 7 + textWidth + 4 + CGFloat(d) * 6, y: 8.5 - CGFloat(b) * 1.2)
                dot.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
                dot.cornerRadius = 1.5
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

    private static func tagWidth(_ word: String) -> CGFloat {
        ceil((word as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width) + 30
    }

    // MARK: Pieces

    private func updateScans(_ t: Double) {
        var seen = Set<ObjectIdentifier>()
        for c in cursors {
            let key = ObjectIdentifier(c)
            guard let r = c.watching, stage < .thinking || t < c.detourUntil, hypot(c.pos.x - (r.minX + r.width * 0.55), c.pos.y - (r.midY + 4)) < 40 else { continue }
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
        let want = stage == .thinking ? 1.0 : 0.0
        fieldAlpha += (want - fieldAlpha) * min(1, dt * (want > fieldAlpha ? 1.2 : 3))
        field.frame = view
        field.opacity = Float(fieldAlpha * (fadeFrom.map { max(0, 1 - (now - $0) / Self.fadeTime) } ?? 1))
        guard fieldAlpha > 0.01 else { return }
        field.time = t
        field.tint = color
        field.glows = cursors.map { CGPoint(x: $0.pos.x - view.minX + 6, y: $0.pos.y - view.minY + 10) }
        field.setNeedsDisplay()
    }

    /// Ghosts draw themselves, one after another.
    private func updateGhosts(_ t: Double) {
        for g in ghosts {
            g.progress = min(1, max(0, (t - g.born) / 0.7))
            g.shape.strokeEnd = g.progress
            g.done = g.progress >= 1
            g.shape.lineDashPhase = CGFloat(-t * 24)
            g.fill.opacity = Float(max(0, (g.progress - 0.6) / 0.4))
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
