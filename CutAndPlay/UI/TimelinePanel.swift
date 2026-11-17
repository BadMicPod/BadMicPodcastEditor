import SwiftUI

struct TimelinePanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(model: model)
            Hairline()
            HStack(spacing: 0) {
                TrackHeaders(model: model, view: model.view)
                    .frame(width: TimelineLayout.headerWidth)
                Hairline(vertical: true)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        TimelineCanvasView(model: model)
                            .clipped()
                        RowScaleBar(model: model, view: model.view)
                            .frame(width: RangeBarStyle.thickness)
                    }
                    HStack(spacing: 0) {
                        ZoomScrollBar(model: model, view: model.view)
                        Theme.panel.frame(width: RangeBarStyle.thickness)
                    }
                    .frame(height: RangeBarStyle.thickness)
                }
            }
        }
        .background(Theme.bg)
    }
}

// MARK: - Toolbar

struct TimelineToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "cursorarrow", active: model.tool == .move, help: "Move (V)") { model.tool = .move }
            IconButton(symbol: "scissors", active: model.tool == .cut, help: "Cut (C)") { model.tool = .cut }
            divider
            SnapButton(active: model.snapping) { model.snapping.toggle() }
            StickyButton(active: model.sticky) { model.sticky.toggle() }
            divider
            IconButton(symbol: "square.split.2x1", help: "Split at Playhead (⌘K)") { model.splitAtPlayhead() }
            IconButton(symbol: "trash", help: "Delete (⌫)") { model.deleteSelection() }
                .disabled(model.selection.isEmpty)
            Spacer()
            IconButton(symbol: "arrow.left.and.right", help: "Zoom to Fit (⇧Z)") { model.zoomToFit() }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Theme.panel)
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 16).padding(.horizontal, 5)
    }
}

/// Snapping toggle: a horseshoe magnet with separated pole tips.
struct SnapButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = active ? Theme.accent : (hovering ? Theme.text : Theme.textDim)
        Button(action: action) {
            MagnetIcon(color: color)
                .frame(width: 13, height: 14)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Snapping (S)")
    }
}

/// Sticky edges toggle: two clips butted together.
struct StickyButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = active ? Theme.accent : (hovering ? Theme.text : Theme.textDim)
        Button(action: action) {
            Canvas { ctx, size in
                let h = size.height * 0.62, y = (size.height - h) / 2
                let w = (size.width - 1.5) / 2
                for x in [0, w + 1.5] {
                    let r = CGRect(x: x, y: y, width: w, height: h)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color))
                }
            }
            .frame(width: 15, height: 14)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Sticky Edges (R): clips touching a clip that changes length move with it")
    }
}

struct MagnetIcon: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            // Upright horseshoe, poles down: a thick arch with two short pole caps split off by a gap.
            let lw = size.width * 0.3
            let inset = lw / 2
            let r = size.width / 2 - inset
            let cx = size.width / 2
            let arcY = inset + r
            let capTop = size.height - size.height * 0.24
            var arch = Path()
            arch.move(to: CGPoint(x: inset, y: capTop - 1.6))
            arch.addLine(to: CGPoint(x: inset, y: arcY))
            arch.addArc(center: CGPoint(x: cx, y: arcY), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            arch.addLine(to: CGPoint(x: size.width - inset, y: capTop - 1.6))
            ctx.stroke(arch, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .butt, lineJoin: .round))
            for x in [inset, size.width - inset] {
                var cap = Path()
                cap.move(to: CGPoint(x: x, y: capTop))
                cap.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(cap, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .butt))
            }
        }
    }
}

// MARK: - Zoom / scroll bars

enum RangeBarStyle {
    static let thickness: CGFloat = 15
    static let handle: CGFloat = 11
}

/// A scrollbar thumb with a grip at each end: drag the middle to scroll, drag a grip to zoom.
private struct RangeThumb: View {
    let vertical: Bool
    let hot: Int?     // 0 = start grip, 1 = body, 2 = end grip
    let active: Bool

    var body: some View {
        let lit = hot != nil || active
        ZStack {
            Capsule().fill(Color.white.opacity(lit ? 0.3 : 0.2))
            if vertical {
                VStack { grip(0); Spacer(minLength: 0); grip(2) }
            } else {
                HStack { grip(0); Spacer(minLength: 0); grip(2) }
            }
        }
    }

    private func grip(_ part: Int) -> some View {
        Circle()
            .fill(Theme.bg)
            // The grips work as a pair, so they light up as a pair.
            .overlay(Circle().strokeBorder(hot == 0 || hot == 2 ? Color.white : Color.white.opacity(0.6), lineWidth: 2))
            .frame(width: RangeBarStyle.handle, height: RangeBarStyle.handle)
    }
}

/// What a bar drag started from. Captured once on mouse-down; every later position is computed
/// from this, never from the previous frame, so a drag can't drift, flip handles or snap.
private final class BarDrag {
    var part = 1
    var pps: CGFloat = 0
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0
    var rowHeight: CGFloat = 0
    var length: CGFloat = 0
    var content: CGFloat = 0
    var start: CGFloat = 0
    var mirror: CGFloat = 1
}

/// Where a thumb's two edges end up when one grip is dragged. The dragged edge follows the mouse
/// exactly; the other edge mirrors it. An edge already at the end of the bar stays there, so the
/// other edge alone carries the change, and a grip at the end can't be pulled further out.
/// `move` is the mouse travel along the bar since the drag began; lengths are in bar points.
/// `mirror` is how far the other edge travels for each point the dragged one does: 1 keeps the
/// middle of the thumb fixed, 0 keeps the other edge fixed.
func gripDrag(part: Int, start a0: CGFloat, end b0: CGFloat, move: CGFloat, bar: CGFloat,
              minLength: CGFloat, maxLength: CGFloat, mirror: CGFloat = 1) -> (start: CGFloat, end: CGFloat) {
    // Positive `grow` pulls the dragged grip outward.
    var grow = part == 2 ? move : -move
    grow = min(grow, part == 2 ? bar - b0 : a0)
    func edges(_ g: CGFloat) -> (start: CGFloat, end: CGFloat) {
        part == 2 ? (max(0, a0 - g * mirror), b0 + g) : (a0 - g, min(bar, b0 + g * mirror))
    }
    func fits(_ g: CGFloat) -> Bool {
        let e = edges(g)
        return e.end - e.start >= minLength - 0.0001 && e.end - e.start <= maxLength + 0.0001
    }
    if !fits(grow) {
        // Length only ever increases with `grow`, so close in on the limit from the starting size.
        var ok: CGFloat = 0, bad = grow
        for _ in 0..<40 {
            let mid = (ok + bad) / 2
            if fits(mid) { ok = mid } else { bad = mid }
        }
        grow = ok
    }
    return edges(grow)
}

private func barPart(at p: CGFloat, thumb: CGFloat, length: CGFloat) -> Int? {
    guard p >= thumb - 2, p <= thumb + length + 2 else { return nil }
    let grip = min(RangeBarStyle.handle + 3, length / 3)
    if p < thumb + grip { return 0 }
    if p > thumb + length - grip { return 2 }
    return 1
}

/// Horizontal bar under the timeline. The bar is the whole scrollable timeline and the thumb is what's
/// on screen. Drag the thumb to scroll; drag either grip to zoom both sides, centred on the playhead.
struct ZoomScrollBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState
    @State private var drag: BarDrag?
    @State private var hot: Int?

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let extent = CGFloat(model.extent)
            let minLen = RangeBarStyle.handle * 2 + 6
            let len = max(minLen, min(1, view.viewWidth / view.pps / extent) * w)
            let x = min(max(0, view.scrollX / view.pps / extent * w), w - len)
            ZStack(alignment: .topLeading) {
                Theme.panel
                RangeThumb(vertical: false, hot: hot, active: drag != nil)
                    .frame(width: len, height: RangeBarStyle.handle)
                    .offset(x: x, y: (geo.size.height - RangeBarStyle.handle) / 2)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard drag == nil else { return }
                if case .active(let p) = phase { hot = barPart(at: p.x, thumb: x, length: len) } else { hot = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let d: BarDrag
                        if let existing = drag {
                            d = existing
                        } else {
                            d = BarDrag()
                            if let part = barPart(at: v.startLocation.x, thumb: x, length: len) {
                                d.part = part
                            } else {
                                // Click on the empty bar: centre the thumb there, then keep dragging it.
                                let start = (v.startLocation.x - len / 2) / w * extent
                                model.setView(scrollX: start * view.pps)
                                d.part = 1
                            }
                            d.pps = view.pps
                            d.scrollX = view.scrollX
                            // Zoom around the playhead: the far edge moves just enough to hold the playhead
                            // where it is on screen. With the playhead at the far edge that edge doesn't move
                            // at all; with it in the middle both edges move equally. If the playhead is off
                            // screen, or nearer the grip being dragged, fall back to the middle of the view.
                            let t = (CGFloat(model.playhead) * view.pps - view.scrollX) / max(1, view.viewWidth)
                            if d.part == 2, t >= 0, t <= 0.5 { d.mirror = t / (1 - t) }
                            else if d.part == 0, t >= 0.5, t <= 1 { d.mirror = (1 - t) / t }
                            else { d.mirror = 1 }
                            drag = d
                            hot = d.part
                        }
                        let dx = v.translation.width
                        if d.part == 1 {
                            model.setView(scrollX: d.scrollX + dx / w * extent * d.pps)
                        } else {
                            // The grip stays under the mouse and the other end mirrors it.
                            let a0 = d.scrollX / d.pps / extent * w
                            let e = gripDrag(part: d.part, start: a0, end: a0 + view.viewWidth / d.pps / extent * w, move: dx, bar: w,
                                             minLength: view.viewWidth / TimelineViewState.maxPPS / extent * w, maxLength: w,
                                             mirror: d.mirror)
                            let pps = view.viewWidth / ((e.end - e.start) / w * extent)
                            model.setView(pps: pps, scrollX: e.start / w * extent * pps)
                        }
                    }
                    .onEnded { _ in
                        drag = nil
                        hot = nil
                    }
            )
        }
        .overlay(Hairline(), alignment: .top)
    }
}

/// Vertical bar beside the timeline. The thumb's length is the row zoom (full bar at the smallest
/// rows) and its position is the scroll. Drag it to scroll; drag either grip to scale rows from both
/// ends, keeping whatever is in the middle of the timeline in the middle.
struct RowScaleBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState
    @State private var drag: BarDrag?
    @State private var hot: Int?

    var body: some View {
        GeometryReader { geo in
            let top = TimelineLayout.ruler
            let h = max(1, geo.size.height - top)
            let minLen = RangeBarStyle.handle * 2 + 6
            let world = model.rowsWorld
            let len = max(minLen, model.rowWindow * h)
            let y = min(max(0, (view.scrollY - model.minScrollY) / world * h), h - len)
            ZStack(alignment: .topLeading) {
                Theme.panel
                RangeThumb(vertical: true, hot: hot, active: drag != nil)
                    .frame(width: RangeBarStyle.handle, height: len)
                    .offset(x: (geo.size.width - RangeBarStyle.handle) / 2, y: top + y)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard drag == nil else { return }
                if case .active(let p) = phase { hot = barPart(at: p.y - top, thumb: y, length: len) } else { hot = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let d: BarDrag
                        if let existing = drag {
                            d = existing
                        } else {
                            d = BarDrag()
                            if let part = barPart(at: v.startLocation.y - top, thumb: y, length: len) {
                                d.part = part
                            } else {
                                model.setView(scrollY: model.minScrollY + (v.startLocation.y - top - len / 2) / h * world)
                                d.part = 1
                            }
                            d.scrollY = view.scrollY
                            d.rowHeight = view.rowHeight
                            d.length = model.rowWindow * h
                            d.content = world
                            d.start = (view.scrollY - model.minScrollY) / world * h
                            drag = d
                            hot = d.part
                        }
                        let dy = v.translation.height
                        if d.part == 1 {
                            model.setView(scrollY: d.scrollY + dy / h * d.content)
                        } else {
                            // A shorter thumb means taller rows. The grip stays under the mouse and the other end mirrors it.
                            let rows = TimelineViewState.rowRange
                            let e = gripDrag(part: d.part, start: d.start, end: d.start + d.length, move: dy, bar: h,
                                             minLength: model.rowWindow(rowHeight: rows.upperBound) * h,
                                             maxLength: model.rowWindow(rowHeight: rows.lowerBound) * h)
                            // Rows are whole points tall, so take the height whose thumb is closest to the one asked for.
                            var best = view.rowHeight, miss = CGFloat.infinity
                            for r in stride(from: rows.lowerBound, through: rows.upperBound, by: 1) {
                                let off = abs(model.rowWindow(rowHeight: r) * h - (e.end - e.start))
                                if off < miss { miss = off; best = r }
                            }
                            model.setView(rowHeight: best)
                            let actual = model.rowWindow * h
                            let top = d.part == 2 ? e.end - actual : e.start
                            model.setView(scrollY: model.minScrollY + top / h * model.rowsWorld)
                        }
                    }
                    .onEnded { _ in
                        drag = nil
                        hot = nil
                    }
            )
        }
        .overlay(Hairline(vertical: true), alignment: .leading)
    }
}

// MARK: - Track headers

struct TrackHeaders: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState

    var body: some View {
        let layout = TimelineLayout(project: model.project, rowHeight: view.rowHeight)
        let ruler = TimelineLayout.ruler
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(layout.rows, id: \.track.id) { row in
                    TrackHeader(model: model, track: row.track,
                                label: (row.track.kind == .video ? "V" : "A") + "\(row.index + 1)",
                                canDelete: model.project.tracks(row.track.kind).count > 1)
                        .frame(width: TimelineLayout.headerWidth, height: row.height)
                        .offset(y: ruler + row.y - view.scrollY)
                }
                AddTrackButton(label: "Video") { model.addTrack(.video) }
                    .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.zone)
                    .offset(y: ruler + layout.videoZoneY - view.scrollY)
                AddTrackButton(label: "Audio") { model.addTrack(.audio) }
                    .frame(width: TimelineLayout.headerWidth, height: TimelineLayout.zone)
                    .offset(y: ruler + layout.audioZoneY - view.scrollY)

                // Corner above the headers, level with the ruler.
                Theme.panel
                    .frame(width: TimelineLayout.headerWidth, height: ruler)
                    .overlay(Hairline(), alignment: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .background(Theme.bg)
    }
}

struct AddTrackButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 10.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(hovering ? Theme.text : Theme.textFaint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add \(label) Track")
    }
}

struct TrackHeader: View {
    @ObservedObject var model: EditorModel
    let track: Track
    let label: String
    let canDelete: Bool

    var body: some View {
        let off = track.kind == .video ? track.hidden : track.muted
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(off ? Theme.textFaint : Theme.text)
                .frame(width: 24, alignment: .leading)
            Spacer(minLength: 0)
            if track.kind == .audio {
                GainPill(db: track.gainDB) { value in
                    model.live(autoCommit: false) { $0.updateTrack(track.id) { $0.gainDB = value } }
                } onEnd: {
                    model.commitLive()
                }
                IconButton(symbol: track.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           active: track.muted, size: 24, help: "Mute") {
                    model.mutate { $0.updateTrack(track.id) { $0.muted.toggle() } }
                }
            } else {
                IconButton(symbol: track.hidden ? "eye.slash" : "eye", active: track.hidden, size: 24, help: "Hide") {
                    model.mutate { $0.updateTrack(track.id) { $0.hidden.toggle() } }
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .overlay(Hairline(), alignment: .bottom)
        .contextMenu {
            Button("Add Video Track") { model.addTrack(.video) }
            Button("Add Audio Track") { model.addTrack(.audio) }
            if canDelete {
                Divider()
                Button("Delete Track") { model.removeTrack(track.id) }
            }
        }
    }
}

/// Track level: drag sideways to change, or click to type a value (Return/click away confirms, Esc cancels).
struct GainPill: View {
    let db: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @State private var hovering = false
    @State private var startDB: Double?
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused, editing { commit() }
                    }
            } else {
                Text(formatDB(db))
            }
        }
        .font(Theme.mono(10))
        .foregroundStyle(editing || abs(db) > 0.05 ? Theme.text : Theme.textDim)
        .frame(width: 58, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering || startDB != nil || editing ? Theme.hover : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(editing ? 0.9 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { v in
                    guard !editing else { return }
                    if startDB == nil { startDB = db }
                    let raw = (startDB ?? 0) + Double(v.translation.width) * 0.15
                    onChange(min(12, max(-60, (raw * 10).rounded() / 10)))
                }
                .onEnded { _ in
                    guard startDB != nil else { return }
                    startDB = nil
                    onEnd()
                }
        )
        .simultaneousGesture(TapGesture().onEnded {
            guard !editing else { return }
            text = db <= -59.5 ? "-60" : String(format: "%.1f", db)
            editing = true
            focused = true
        })
        .help("Track level — drag, or click to type")
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
            .filter { "0123456789.-".contains($0) }
        if let v = Double(cleaned) {
            onChange(min(12, max(-60, (v * 10).rounded() / 10)))
            onEnd()
        }
        editing = false
    }
}
