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
    @State private var dragStart: (x: Double, y: Double)?

    /// A single selected text clip can be repositioned by dragging in the viewer.
    private var draggableText: Clip? {
        guard model.selection.count == 1, let id = model.selection.first,
              let c = model.project.clip(id), c.kind == .text else { return nil }
        return c
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let aspect = model.project.aspect
                let w = min(geo.size.width, geo.size.height * aspect)
                let h = w / aspect
                PreviewSurfaceView(model: model)
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                guard let clip = draggableText else { return }
                                if dragStart == nil { dragStart = (clip.text.x, clip.text.y) }
                                guard let s = dragStart else { return }
                                let nx = min(1, max(0, s.x + Double(v.translation.width / w)))
                                let ny = min(1, max(0, s.y + Double(v.translation.height / h)))
                                model.live(autoCommit: false) { p in
                                    if let i = p.index(of: clip.id) {
                                        p.clips[i].text.x = nx
                                        p.clips[i].text.y = ny
                                    }
                                }
                            }
                            .onEnded { _ in
                                dragStart = nil
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
