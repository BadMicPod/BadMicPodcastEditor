import SwiftUI
import AppKit
import AVFoundation

/// Displays decoded frames straight from the player's video output. The last frame stays up while
/// a new composition is swapped in, so edits never flash black.
final class PreviewSurface: NSView {
    private let model: EditorModel
    private var link: CADisplayLink?
    private var current: CVPixelBuffer?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ sender: CADisplayLink) {
        if let buffer = model.engine.pullFrame() {
            current = buffer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            CATransaction.commit()
        } else if model.engine.isEmpty, current != nil {
            current = nil
            layer?.contents = nil
        }
        model.tick()
    }
}

struct PreviewSurfaceView: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface(model: model) }
    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}

struct PreviewView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: Clock
    @State private var moveStart: (x: Double, y: Double)?
    @State private var scaleStart: (scale: Double, distance: CGFloat)?

    init(model: EditorModel) {
        self.model = model
        self.clock = model.clock
    }

    /// The one visual clip in the selection, which dragging in the viewer moves.
    private var target: Clip? {
        let visual = model.selection.compactMap { model.project.clip($0) }.filter { $0.kind != .audio }
        return visual.count == 1 ? visual[0] : nil
    }

    /// Where a transformable clip sits in a viewer of the given size, before any drag.
    private func box(_ c: Clip, w: CGFloat, h: CGFloat) -> CGRect {
        var size = CGSize(width: w, height: h)
        if c.kind != .solid, let a = model.project.asset(c.assetID), a.width > 0, a.height > 0 {
            let s = min(w / CGFloat(a.width), h / CGFloat(a.height))
            size = CGSize(width: CGFloat(a.width) * s, height: CGFloat(a.height) * s)
        }
        let tf = c.transform ?? ClipTransform()
        size = CGSize(width: size.width * tf.scale, height: size.height * tf.scale)
        let center = CGPoint(x: w / 2 + tf.x * w, y: h / 2 + tf.y * h)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func setTransform(_ id: UUID, _ body: @escaping (inout ClipTransform) -> Void) {
        model.live(autoCommit: false) { p in
            guard let i = p.index(of: id) else { return }
            var t = p.clips[i].transform ?? ClipTransform()
            body(&t)
            p.clips[i].transform = t.isIdentity ? nil : t
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let aspect = model.project.aspect
                let w = min(geo.size.width, geo.size.height * aspect)
                let h = w / aspect
                let clip = target
                let now = Double(clock.frame) / model.project.fps + 1e-6
                let playheadOver = clip.map { now >= $0.start && now < $0.end } ?? false
                ZStack(alignment: .topLeading) {
                    PreviewSurfaceView(model: model)
                        .frame(width: w, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
                    if let c = clip, c.isTransformable, playheadOver, !model.isPlaying {
                        TransformBox(rect: box(c, w: w, h: h)) { corner, value in
                            let r = box(c, w: w, h: h)
                            let center = CGPoint(x: r.midX, y: r.midY)
                            let start = CGPoint(x: value.startLocation.x, y: value.startLocation.y)
                            if scaleStart == nil {
                                scaleStart = ((c.transform ?? ClipTransform()).scale, max(4, hypot(start.x - center.x, start.y - center.y)))
                            }
                            guard let s0 = scaleStart else { return }
                            let d = hypot(value.location.x - center.x, value.location.y - center.y)
                            let scale = (s0.scale * Double(d / s0.distance)).clamped(to: ClipTransform.scaleRange)
                            // Settle on exactly 100% when close to it.
                            setTransform(c.id) { $0.scale = abs(scale - 1) < 0.02 ? 1 : (scale * 1000).rounded() / 1000 }
                            _ = corner
                        } onEnd: {
                            scaleStart = nil
                            model.commitLive()
                        }
                    }
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .coordinateSpace(name: "viewer")
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("viewer"))
                        .onChanged { v in
                            guard let c = target else { return }
                            if c.kind == .text {
                                if moveStart == nil { moveStart = (c.text.x, c.text.y) }
                                guard let s = moveStart else { return }
                                let nx = min(1, max(0, s.x + Double(v.translation.width / w)))
                                let ny = min(1, max(0, s.y + Double(v.translation.height / h)))
                                model.live(autoCommit: false) { p in
                                    if let i = p.index(of: c.id) {
                                        p.clips[i].text.x = nx
                                        p.clips[i].text.y = ny
                                    }
                                }
                            } else if c.isTransformable {
                                let tf = c.transform ?? ClipTransform()
                                if moveStart == nil { moveStart = (tf.x, tf.y) }
                                guard let s = moveStart else { return }
                                var nx = s.x + Double(v.translation.width / w)
                                var ny = s.y + Double(v.translation.height / h)
                                // Snap back to centre within a few points.
                                if abs(nx) * Double(w) < 5 { nx = 0 }
                                if abs(ny) * Double(h) < 5 { ny = 0 }
                                let width = Double(model.project.width), height = Double(model.project.height)
                                setTransform(c.id) {
                                    $0.x = (nx * width).rounded() / width
                                    $0.y = (ny * height).rounded() / height
                                }
                            }
                        }
                        .onEnded { _ in
                            moveStart = nil
                            model.commitLive()
                        }
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            TransportBar(model: model, clock: model.clock)
        }
        .background(Theme.bg)
    }
}

/// Outline of the selected clip in the viewer, with a handle at each corner to scale it.
private struct TransformBox: View {
    let rect: CGRect
    let onScale: (Int, DragGesture.Value) -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.black.opacity(0.5), lineWidth: 3)
                .overlay(Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1).padding(1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            ForEach(0..<4, id: \.self) { corner in
                let p = CGPoint(x: corner % 2 == 0 ? rect.minX : rect.maxX, y: corner < 2 ? rect.minY : rect.maxY)
                Rectangle()
                    .fill(Color.white)
                    .overlay(Rectangle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
                    .frame(width: 9, height: 9)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                            .onChanged { onScale(corner, $0) }
                            .onEnded { _ in onEnd() }
                    )
                    .offset(x: p.x - 10, y: p.y - 10)
            }
        }
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: Clock

    var body: some View {
        let fps = model.project.fps
        ZStack {
            HStack {
                Text(Timecode.string(Double(clock.frame) / fps, fps: fps))
                    .font(Theme.mono(13, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(Timecode.string(model.project.duration, fps: fps))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
            }
            HStack(spacing: 2) {
                IconButton(symbol: "backward.end.fill", size: 30, help: "Previous Edit (↑)") { model.jumpToEdit(forward: false) }
                IconButton(symbol: "backward.frame.fill", size: 30, help: "Back One Frame (←)") { model.step(frames: -1) }
                PlayButton(playing: model.isPlaying) { model.togglePlay() }
                    .padding(.horizontal, 6)
                IconButton(symbol: "forward.frame.fill", size: 30, help: "Forward One Frame (→)") { model.step(frames: 1) }
                IconButton(symbol: "forward.end.fill", size: 30, help: "Next Edit (↓)") { model.jumpToEdit(forward: true) }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }
}

private struct PlayButton: View {
    let playing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.88))
                .offset(x: playing ? 0 : 1)
                .frame(width: 36, height: 36)
                .background(Circle().fill(hovering ? Color.white : Color.white.opacity(0.9)))
                .scaleEffect(hovering ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Play / Pause (Space)")
    }
}
