import SwiftUI

struct TimelinePanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(model: model, view: model.view)
            Hairline()
            HStack(spacing: 0) {
                TrackHeaders(model: model, view: model.view)
                    .frame(width: TimelineLayout.headerWidth)
                Hairline(vertical: true)
                TimelineCanvasView(model: model)
            }
        }
        .background(Theme.bg)
    }
}

// MARK: - Toolbar

struct TimelineToolbar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState

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
            divider
            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { model.undo() }
                .disabled(!model.canUndo)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { model.redo() }
                .disabled(!model.canRedo)

            Spacer()

            IconButton(symbol: "arrow.left.and.right", help: "Zoom to Fit (⇧Z)") { model.zoomToFit() }
            IconButton(symbol: "minus", size: 24, help: "Zoom Out (−)") { model.zoom(by: 1 / 1.4) }
            Slider(value: Binding(
                get: { log(Double(view.pps)) },
                set: { model.setZoom(CGFloat(exp($0))) }
            ), in: log(Double(TimelineViewState.minPPS))...log(Double(TimelineViewState.maxPPS)))
                .controlSize(.mini)
                .tint(Theme.textDim)
                .frame(width: 120)
            IconButton(symbol: "plus", size: 24, help: "Zoom In (+)") { model.zoom(by: 1.4) }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Theme.panel)
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 16).padding(.horizontal, 5)
    }
}

/// Snapping toggle with a hand-drawn magnet glyph.
struct SnapButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MagnetShape()
                .stroke(active ? Theme.accent : (hovering ? Theme.text : Theme.textDim),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .butt))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(180))
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

struct MagnetShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.width / 2
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

// MARK: - Track headers

struct TrackHeaders: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var view: TimelineViewState

    var body: some View {
        let layout = TimelineLayout(project: model.project)
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

/// Track level readout: drag sideways to change, double-click to reset.
struct GainPill: View {
    let db: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    @State private var hovering = false
    @State private var startDB: Double?

    var body: some View {
        Text(formatDB(db))
            .font(Theme.mono(10))
            .foregroundStyle(abs(db) > 0.05 ? Theme.text : Theme.textDim)
            .frame(width: 58, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering || startDB != nil ? Theme.hover : Theme.field))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if startDB == nil { startDB = db }
                        let raw = (startDB ?? 0) + Double(v.translation.width) * 0.15
                        onChange(min(12, max(-60, (raw * 10).rounded() / 10)))
                    }
                    .onEnded { _ in
                        startDB = nil
                        onEnd()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                onChange(0)
                onEnd()
            })
            .help("Track level — drag to adjust")
    }
}
