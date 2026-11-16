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
            .overlay(Circle().strokeBorder(hot == part ? Theme.accent : Color.white.opacity(0.75), lineWidth: 2))
            .frame(width: RangeBarStyle.handle, height: RangeBarStyle.handle)
    }
}

/// Horizontal bar under the timeline: position and length of the thumb are the visible time range.
struct ZoomScrollBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState
    @State private var origin: (total: Double, start: Double, end: Double, part: Int)?
    @State private var hot: Int?

    private var visibleStart: Double { Double(view.scrollX / view.pps) }
    private var visibleEnd: Double { Double((view.scrollX + view.viewWidth) / view.pps) }
    private var total: Double {
        origin?.total ?? max(model.project.duration * 1.15, visibleEnd, 1)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = total
            let x0 = CGFloat(visibleStart / t) * w
            let len = max(RangeBarStyle.handle * 2 + 6, CGFloat((visibleEnd - visibleStart) / t) * w)
            let x = min(x0, w - len)
            ZStack(alignment: .topLeading) {
                Theme.panel
                RangeThumb(vertical: false, hot: hot, active: origin != nil)
                    .frame(width: len, height: RangeBarStyle.handle)
                    .offset(x: x, y: (geo.size.height - RangeBarStyle.handle) / 2)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hot = part(at: p.x, thumbX: x, length: len) } else if origin == nil { hot = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if origin == nil {
                            var part = part(at: v.startLocation.x, thumbX: x, length: len)
                            if part == nil {
                                // Click on the track: jump the thumb there, then drag it.
                                let span = visibleEnd - visibleStart
                                let start = max(0, min(t - span, Double(v.startLocation.x / w) * t - span / 2))
                                view.scrollX = CGFloat(start) * view.pps
                                part = 1
                            }
                            origin = (t, visibleStart, visibleEnd, part ?? 1)
                            hot = part
                        }
                        guard let o = origin else { return }
                        let dt = Double(v.translation.width / w) * o.total
                        let minSpan = Double(view.viewWidth / TimelineViewState.maxPPS)
                        let maxSpan = Double(view.viewWidth / TimelineViewState.minPPS)
                        switch o.part {
                        case 0:
                            let start = max(0, min(o.start + dt, o.end - minSpan))
                            apply(start: start, span: min(maxSpan, o.end - start))
                        case 2:
                            let end = max(o.start + minSpan, min(o.end + dt, o.total))
                            apply(start: o.start, span: min(maxSpan, end - o.start))
                        default:
                            let span = o.end - o.start
                            view.scrollX = CGFloat(max(0, min(o.start + dt, o.total - span))) * view.pps
                        }
                    }
                    .onEnded { _ in
                        origin = nil
                        hot = nil
                    }
            )
        }
        .overlay(Hairline(), alignment: .top)
    }

    private func part(at px: CGFloat, thumbX: CGFloat, length: CGFloat) -> Int? {
        guard px >= thumbX - 2, px <= thumbX + length + 2 else { return nil }
        if px < thumbX + RangeBarStyle.handle + 2 { return 0 }
        if px > thumbX + length - RangeBarStyle.handle - 2 { return 2 }
        return 1
    }

    private func apply(start: Double, span: Double) {
        let pps = view.viewWidth / CGFloat(span)
        view.pps = pps
        view.scrollX = CGFloat(start) * pps
    }
}

/// Vertical bar beside the timeline. The thumb's length is the row zoom: full length at the smallest
/// rows, shortest at the largest. Drag a grip to scale rows, drag the middle to scroll tracks.
struct RowScaleBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState
    @State private var origin: (scrollY: CGFloat, length: CGFloat, y: CGFloat, part: Int)?
    @State private var hot: Int?

    private var trackCount: CGFloat { CGFloat(model.project.videoTracks.count + model.project.audioTracks.count) }
    private var visible: CGFloat { max(40, view.viewHeight - TimelineLayout.ruler) }
    private var maxScroll: CGFloat {
        max(0, TimelineLayout.fixedHeight + trackCount * (view.rowHeight + TimelineLayout.gap) - visible)
    }

    var body: some View {
        GeometryReader { geo in
            let top = TimelineLayout.ruler
            let h = max(1, geo.size.height - top)
            let minRow = TimelineViewState.rowRange.lowerBound
            let len = h * minRow / view.rowHeight
            let y = maxScroll > 0 ? min(1, view.scrollY / maxScroll) * (h - len) : 0
            ZStack(alignment: .topLeading) {
                Theme.panel
                RangeThumb(vertical: true, hot: hot, active: origin != nil)
                    .frame(width: RangeBarStyle.handle, height: len)
                    .offset(x: (geo.size.width - RangeBarStyle.handle) / 2, y: top + y)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hot = part(at: p.y - top, thumbY: y, length: len) } else if origin == nil { hot = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if origin == nil {
                            let part = part(at: v.startLocation.y - top, thumbY: y, length: len) ?? 1
                            origin = (view.scrollY, len, y, part)
                            hot = part
                        }
                        guard let o = origin else { return }
                        let dy = v.translation.height
                        if o.part == 1 {
                            let travel = h - o.length
                            guard travel > 0, maxScroll > 0 else { return }
                            view.scrollY = max(0, min(1, (o.y + dy) / travel)) * maxScroll
                            return
                        }
                        // A shorter thumb means taller rows; the thumb can't grow past the bar or shrink past max zoom.
                        let minLen = h * minRow / TimelineViewState.rowRange.upperBound
                        let newLen = max(minLen, min(h, o.part == 0 ? o.length - dy : o.length + dy))
                        view.rowHeight = (minRow * h / newLen).rounded()
                        view.scrollY = min(view.scrollY, maxScroll)
                    }
                    .onEnded { _ in
                        origin = nil
                        hot = nil
                    }
            )
        }
        .overlay(Hairline(vertical: true), alignment: .leading)
    }

    private func part(at py: CGFloat, thumbY: CGFloat, length: CGFloat) -> Int? {
        guard py >= thumbY - 2, py <= thumbY + length + 2 else { return nil }
        if py < thumbY + RangeBarStyle.handle + 2 { return 0 }
        if py > thumbY + length - RangeBarStyle.handle - 2 { return 2 }
        return 1
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
