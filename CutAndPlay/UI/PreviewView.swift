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
        // A viewer that has just appeared (full screen, say) starts on the frame already showing.
        if current == nil, let last = model.engine.lastFrame {
            current = last
            layer?.contents = CVPixelBufferGetIOSurface(last)?.takeUnretainedValue()
        }
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
    /// Viewer magnification; nil fits the frame to the space available.
    @State private var zoom: Double?

    init(model: EditorModel) {
        self.model = model
        self.clock = model.clock
    }

    /// The one visual clip in the selection, which dragging in the viewer moves.
    private var target: Clip? {
        let visual = model.selection.compactMap { model.project.clip($0) }.filter { $0.kind != .audio }
        return visual.count == 1 ? visual[0] : nil
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
                let fit = min(geo.size.width, geo.size.height * aspect)
                // 100% is one frame pixel per screen pixel.
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let w = zoom.map { CGFloat(Double(model.project.width) * $0) / scale } ?? fit
                let h = w / aspect
                let viewer = picture(w: w, h: h)
                if w <= geo.size.width + 0.5 && h <= geo.size.height + 0.5 {
                    viewer.position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        viewer.frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            TransportBar(model: model, clock: model.clock, meters: model.meters, zoom: $zoom)
        }
        .background(model.viewerOnly ? Color.black : Theme.bg)
    }

    @ViewBuilder private func picture(w: CGFloat, h: CGFloat) -> some View {
                let clip = target
                ZStack(alignment: .topLeading) {
                    PreviewSurfaceView(model: model)
                        .frame(width: w, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
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
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var clock: Clock
    let meters: MeterState
    @Binding var zoom: Double?

    private static let zooms: [(String, Double?)] = [("Fit", nil), ("25%", 0.25), ("50%", 0.5), ("100%", 1), ("200%", 2)]

    var body: some View {
        let fps = model.project.fps
        ZStack {
            HStack(spacing: 8) {
                TimecodeField(time: Double(clock.frame) / fps, fps: fps) { model.seek(to: $0) }
                Text("/ " + Timecode.string(model.project.duration, fps: fps))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                IconButton(symbol: "repeat", active: model.loop, size: 28, help: "Loop Playback (L)") { model.loop.toggle() }
                LevelMeter(meters: meters)
                    .frame(width: 6, height: 24)
                    .padding(.horizontal, 6)
                    .help("Output level")
                Menu {
                    ForEach(Self.zooms, id: \.0) { item in
                        Button(item.0) { zoom = item.1 }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.zooms.first { $0.1 == zoom }?.0 ?? "Fit")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Viewer zoom")
                IconButton(symbol: model.viewerOnly ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           size: 28, help: model.viewerOnly ? "Exit Full Screen (F or Esc)" : "Full Screen Viewer (F)") {
                    model.toggleViewerFullScreen()
                }
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

/// The current time. Click it to type a time to jump to: Return or clicking away goes there, Esc cancels.
private struct TimecodeField: View {
    let time: Double
    let fps: Double
    let onJump: (Double) -> Void
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused, editing { commit() }
                    }
            } else {
                Text(Timecode.string(time, fps: fps))
            }
        }
        .font(Theme.mono(19, .medium))
        .foregroundStyle(Theme.text)
        .frame(width: 150, alignment: .leading)
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(editing || hovering ? Theme.field : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(editing ? 0.9 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !editing else { return }
            text = Timecode.string(time, fps: fps)
            editing = true
            focused = true
        }
        .padding(.leading, -7)
        .help("Click to type a time")
    }

    private func commit() {
        if let t = Timecode.parse(text, fps: fps) { onJump(t) }
        editing = false
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
