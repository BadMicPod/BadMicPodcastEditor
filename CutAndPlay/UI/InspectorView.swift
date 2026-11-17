import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InspectorView: View {
    static let width: CGFloat = 320

    @ObservedObject var model: EditorModel
    @State private var speedOrigin: [Clip]?

    private var selected: [Clip] {
        model.project.clips.filter { model.selection.contains($0.id) }
    }

    var body: some View {
        let clips = selected
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Group {
                    if !clips.isEmpty, clips.allSatisfy({ $0.kind == .solid }) {
                        SolidIcon().frame(width: 15, height: 11)
                    } else {
                        Image(systemName: headerSymbol(clips)).font(.system(size: 12, weight: .medium))
                    }
                }
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 18)
                Text(title(clips))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if clips.isEmpty {
                        sequenceSection
                    } else {
                        clipSections(clips)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 18)
            }
        }
        .background(Theme.panel)
    }

    private func primary(_ clips: [Clip]) -> Clip? {
        clips.first { $0.kind != .audio } ?? clips.first
    }

    private func title(_ clips: [Clip]) -> String {
        if clips.isEmpty { return "Sequence" }
        let groups = Set(clips.map { $0.linkID ?? $0.id })
        if groups.count == 1, let c = primary(clips) { return model.project.name(of: c) }
        return "\(clips.count) clips"
    }

    private func headerSymbol(_ clips: [Clip]) -> String {
        guard let c = primary(clips) else { return "rectangle.on.rectangle" }
        if Set(clips.map { $0.linkID ?? $0.id }).count > 1 { return "square.stack" }
        switch c.kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .text: return "textformat"
        case .solid: return "square.fill"
        }
    }

    // MARK: Sequence

    private static let sizes: [(String, Int, Int)] = [
        ("4K  3840 × 2160", 3840, 2160),
        ("1440p  2560 × 1440", 2560, 1440),
        ("1080p  1920 × 1080", 1920, 1080),
        ("720p  1280 × 720", 1280, 720),
        ("Vertical  1080 × 1920", 1080, 1920),
        ("Vertical 4K  2160 × 3840", 2160, 3840),
        ("Square  1080 × 1080", 1080, 1080),
    ]

    @ViewBuilder private var sequenceSection: some View {
        let p = model.project
        InspectorSection("Frame") {
            MenuField(label: "\(p.width) × \(p.height)") {
                ForEach(Self.sizes, id: \.0) { item in
                    Button(item.0) { model.setSequence(width: item.1, height: item.2) }
                }
            }
            FrameSizeFields(width: p.width, height: p.height) { w, h in
                model.setSequence(width: w, height: h)
            }
        }
        InspectorSection("Frame rate") {
            MenuField(label: Self.fpsLabel(p.fps)) {
                ForEach(EditorModel.frameRates, id: \.self) { rate in
                    Button(Self.fpsLabel(rate)) { model.setFPS(rate) }
                }
            }
        }
    }

    static func fpsLabel(_ fps: Double) -> String {
        (abs(fps - fps.rounded()) < 0.001 ? String(Int(fps)) : String(format: "%.2f", fps)) + " fps"
    }

    // MARK: Clips

    @ViewBuilder private func clipSections(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let visual = clips.filter { $0.kind != .audio }
        let audio = clips.filter { $0.kind == .audio }
        let sourced = clips.filter { $0.kind.usesSource }
        let offSpeed = sourced.first.map { abs($0.speed - 1) > 0.001 } ?? false
        let offGain = audio.first.map { abs($0.gainDB) > 0.001 } ?? false

        if sourced.first != nil || audio.first != nil {
            InspectorSection("Playback", action: offSpeed ? ("Reset speed", { model.setSpeed(1) }) : nil, marked: offSpeed || offGain) {
                if let first = sourced.first {
                    ParamRow(icon: .symbol("clock.arrow.circlepath"), label: "Speed",
                             value: first.speed * 100, range: 10...5000, logarithmic: true,
                             format: { "\(Int($0.rounded()))%" },
                             onEditing: { began in
                                 if began {
                                     speedOrigin = model.project.clips
                                 } else {
                                     speedOrigin = nil
                                     model.commitLive()
                                 }
                             },
                             onChange: { applySpeed($0 / 100, ids: ids) })
                }
                if let first = audio.first {
                    ParamRow(icon: .symbol("speaker.wave.2"), label: "Volume",
                             value: first.gainDB, range: -60...12, format: formatDB,
                             onEditing: { if !$0 { model.commitLive() } },
                             onChange: { v in
                                 let audioIDs = Set(audio.map(\.id))
                                 model.live(autoCommit: false) { p in
                                     for i in p.clips.indices where audioIDs.contains(p.clips[i].id) { p.clips[i].gainDB = (v * 10).rounded() / 10 }
                                 }
                             })
                }
            }
        }

        let movable = visual.filter(\.isTransformable)
        if !movable.isEmpty {
            transformSection(movable)
        } else if visual.count == 1, visual[0].kind == .text {
            textTransformSection(visual[0])
        }
        if visual.count == 1 { transitionSection(visual[0]) }
        if !visual.isEmpty { fadeSection(audio.isEmpty ? "Fade" : "Video fade", visual) }
        if !audio.isEmpty { fadeSection(visual.isEmpty ? "Fade" : "Audio fade", audio) }
        if !visual.isEmpty { colorSection(visual) }

        if clips.count == 1, let c = clips.first {
            if c.kind == .text { textSection(c) }
            if c.kind == .solid {
                InspectorSection("Fill") {
                    ColorField(color: c.color) { color in
                        model.live { p in
                            if let i = p.index(of: c.id) { p.clips[i].color = color }
                        }
                    }
                }
            }
        }
    }

    private func applySpeed(_ speed: Double, ids: Set<UUID>) {
        guard let origin = speedOrigin else {
            model.setSpeed(speed)
            return
        }
        // Always derive from the clips as they were when the drag began, so rounding never accumulates.
        model.live(autoCommit: false) { p in
            p.clips = origin
            p.setSpeed(ids: p.linked(ids), speed: speed, sticky: model.sticky)
        }
    }

    @ViewBuilder private func transformSection(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let tf = clips[0].transform ?? ClipTransform()
        let w = Double(model.project.width), h = Double(model.project.height)
        let live: (@escaping (inout ClipTransform) -> Void) -> Void = { body in
            model.live(autoCommit: false) { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var t = p.clips[i].transform ?? ClipTransform()
                    body(&t)
                    p.clips[i].transform = t.isIdentity ? nil : t
                }
            }
        }
        let done: (Bool) -> Void = { if !$0 { model.commitLive() } }
        InspectorSection("Transform", action: tf.isIdentity ? nil : ("Reset", {
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].transform = nil }
            }
        }), collapsedByDefault: true, marked: !tf.isIdentity) {
            ParamRow(icon: .symbol("arrow.up.left.and.arrow.down.right"), label: "Scale", value: tf.scale * 100,
                     range: 5...1000, logarithmic: true, format: { "\(Int($0.rounded()))%" }, onEditing: done,
                     onChange: { v in live { $0.scale = (v.rounded() / 100).clamped(to: ClipTransform.scaleRange) } })
            ParamRow(icon: .symbol("arrow.left.and.right"), label: "X", value: tf.x * w, range: -w...w,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.x = v.rounded() / w } })
            ParamRow(icon: .symbol("arrow.up.and.down"), label: "Y", value: tf.y * h, range: -h...h,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.y = v.rounded() / h } })
        }
    }

    /// Transitions on the cuts either side of a clip: In blends from the clip before, Out into the clip after.
    @ViewBuilder private func transitionSection(_ c: Clip) -> some View {
        let p = model.project
        let before = p.previous(touching: c)
        let after = p.next(touching: c)
        if before != nil || after != nil {
            let incoming = before != nil ? c : nil
            let outgoing = after
            let marked = incoming?.transitionIn != nil || outgoing?.transitionIn != nil
            InspectorSection("Transitions", collapsedByDefault: true, marked: marked) {
                if let clip = incoming, let a = before { transitionRows("In", into: clip, from: a) }
                if let clip = outgoing { transitionRows("Out", into: clip, from: c) }
            }
        }
    }

    @ViewBuilder private func transitionRows(_ label: String, into clip: Clip, from a: Clip) -> some View {
        let t = clip.transitionIn
        HStack(spacing: 8) {
            Image(systemName: label == "In" ? "arrow.right.to.line" : "arrow.right.to.line.compact")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .frame(width: 52, alignment: .leading)
            MenuField(label: t?.kind.label ?? "None", height: 26) {
                Button("None") { model.setTransition(into: clip.id, nil) }
                Divider()
                ForEach(TransitionKind.allCases, id: \.self) { kind in
                    Button(kind.label) {
                        var n = t ?? Transition()
                        n.kind = kind
                        model.setTransition(into: clip.id, n)
                    }
                }
            }
        }
        .frame(height: 28)
        if let t {
            let span = model.project.transitionSpan(from: a, into: clip)
            let actual = span.map { $0.end - $0.start } ?? 0
            ParamRow(icon: .symbol("timer"), label: "Length", value: t.duration, range: 0.1...5,
                     format: { String(format: "%.2fs", $0) },
                     onEditing: { if !$0 { model.commitLive() } },
                     onChange: { v in
                         model.live(autoCommit: false) { p in
                             if let i = p.index(of: clip.id) { p.clips[i].transitionIn?.duration = (v * 100).rounded() / 100 }
                         }
                     })
            if actual < t.duration - 0.01 {
                Text(actual > 0 ? String(format: "Shortened to %.2fs: no more media beyond the cut.", actual)
                                : "Needs media beyond the cut to blend; try Dip to Black.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.leading, 26)
            }
        }
    }

    @ViewBuilder private func fadeSection(_ title: String, _ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let first = clips[0]
        let maxFade = max(0.1, min(first.duration, 10))
        InspectorSection(title, collapsedByDefault: true, marked: first.fadeIn > 0 || first.fadeOut > 0) {
            ParamRow(icon: .fadeIn, label: "Fade In",
                     value: first.fadeIn, range: 0...maxFade, format: { String(format: "%.2fs", $0) },
                     onEditing: { if !$0 { model.commitLive() } },
                     onChange: { v in
                         model.live(autoCommit: false) { p in
                             for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                 p.clips[i].fadeIn = min(p.snapFrame(v), p.clips[i].duration - p.clips[i].fadeOut)
                             }
                         }
                     },
                     trailing: AnyView(CurveMenu(selection: first.inCurve, rising: true, active: first.fadeIn > 0) { curve in
                         model.mutate { p in
                             for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].fadeInCurve = curve }
                         }
                     }))
            ParamRow(icon: .fadeOut, label: "Fade Out",
                     value: first.fadeOut, range: 0...maxFade, format: { String(format: "%.2fs", $0) },
                     onEditing: { if !$0 { model.commitLive() } },
                     onChange: { v in
                         model.live(autoCommit: false) { p in
                             for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                 p.clips[i].fadeOut = min(p.snapFrame(v), p.clips[i].duration - p.clips[i].fadeIn)
                             }
                         }
                     },
                     trailing: AnyView(CurveMenu(selection: first.outCurve, rising: false, active: first.fadeOut > 0) { curve in
                         model.mutate { p in
                             for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].fadeOutCurve = curve }
                         }
                     }))
        }
    }

    @ViewBuilder private func colorSection(_ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let grade = clips[0].grade ?? ColorGrade()
        let live: (@escaping (inout ColorGrade) -> Void) -> Void = { body in
            model.live(autoCommit: false) { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var g = p.clips[i].grade ?? ColorGrade()
                    body(&g)
                    p.clips[i].grade = g.isNeutral ? nil : g
                }
            }
        }
        let once: (@escaping (inout ColorGrade) -> Void) -> Void = { body in
            model.mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) {
                    var g = p.clips[i].grade ?? ColorGrade()
                    body(&g)
                    p.clips[i].grade = g.isNeutral ? nil : g
                }
            }
        }
        let done: (Bool) -> Void = { editing in
            if !editing { model.commitLive() }
        }
        InspectorSection("Color", action: grade.isNeutral ? nil : ("Reset", { once { $0 = ColorGrade() } }),
                         collapsedByDefault: true, marked: !grade.isNeutral) {
            HStack(alignment: .top, spacing: 0) {
                ColorWheel(title: "Shadows", point: grade.shadows, onChange: { pt in live { $0.shadows = pt } }, onEnd: { model.commitLive() })
                ColorWheel(title: "Midtones", point: grade.midtones, onChange: { pt in live { $0.midtones = pt } }, onEnd: { model.commitLive() })
                ColorWheel(title: "Highlights", point: grade.highlights, onChange: { pt in live { $0.highlights = pt } }, onEnd: { model.commitLive() })
            }
            .padding(.vertical, 4)
            ParamRow(icon: .symbol("sun.max"), label: "Exposure", value: grade.exposure, range: -2...2,
                     format: { String(format: "%+.2f", $0) }, onEditing: done,
                     onChange: { v in live { $0.exposure = (v * 100).rounded() / 100 } })
            ParamRow(icon: .symbol("circle.lefthalf.filled"), label: "Contrast", value: grade.contrast, range: -50...50,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.contrast = v.rounded() } })
            ParamRow(icon: .symbol("drop"), label: "Saturate", value: grade.saturation, range: -100...100,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.saturation = v.rounded() } })
            ParamRow(icon: .symbol("thermometer.medium"), label: "Temp", value: grade.temperature, range: -50...50,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.temperature = v.rounded() } })
            ParamRow(icon: .symbol("eyedropper"), label: "Tint", value: grade.tint, range: -50...50,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in live { $0.tint = v.rounded() } })
            HStack(spacing: 8) {
                Image(systemName: "camera.filters").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 18)
                Text("Look")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .frame(width: 52, alignment: .leading)
                MenuField(label: grade.lookLabel, height: 26) {
                    Button("None") { once { $0.look = nil } }
                    Divider()
                    ForEach(BuiltInLook.all, id: \.name) { item in
                        Button(item.name) { once { $0.look = item.name } }
                    }
                    Divider()
                    Button("Load .cube…") {
                        if let path = chooseCube() { once { $0.look = path } }
                    }
                }
            }
            .frame(height: 28)
            if grade.look != nil {
                ParamRow(icon: .symbol("circle.dotted"), label: "Intensity", value: grade.lookIntensity * 100, range: 0...100,
                         format: { "\(Int($0.rounded()))%" }, onEditing: done,
                         onChange: { v in live { $0.lookIntensity = v.rounded() / 100 } })
            }
        }
    }

    private func chooseCube() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard GradeBaker.cubeFile(url.path) != nil else {
            model.importError = "“\(url.lastPathComponent)” isn't a 3D .cube LUT this app can read."
            return nil
        }
        return url.path
    }

    @ViewBuilder private func textSection(_ c: Clip) -> some View {
        let update: (@escaping (inout TextStyle) -> Void) -> Void = { body in
            model.live { p in
                if let i = p.index(of: c.id) { body(&p.clips[i].text) }
            }
        }
        InspectorSection("Text") {
            TextEditor(text: Binding(get: { c.text.string }, set: { s in update { $0.string = s } }))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 68)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            FontPicker(selection: c.text.fontName) { family in update { $0.fontName = family } }
            HStack(spacing: 8) {
                Chip(label: "Bold", active: c.text.bold) { update { $0.bold.toggle() } }
                ColorField(color: c.text.color) { color in update { $0.color = color } }
            }
            ParamRow(icon: .symbol("textformat.size"), label: "Size", value: c.text.size, range: 12...600, logarithmic: true,
                     format: { "\(Int($0.rounded()))" },
                     onEditing: { if !$0 { model.commitLive() } },
                     onChange: { v in update { $0.size = v.rounded() } })
        }
    }

    /// Position for a text clip, in frame pixels from the centre like other clips. No scale: the
    /// font size does that and keeps the text sharp.
    @ViewBuilder private func textTransformSection(_ c: Clip) -> some View {
        let w = Double(model.project.width), h = Double(model.project.height)
        let centred = abs(c.text.x - 0.5) < 1e-6 && abs(c.text.y - 0.5) < 1e-6
        let update: (@escaping (inout TextStyle) -> Void) -> Void = { body in
            model.live(autoCommit: false) { p in
                if let i = p.index(of: c.id) { body(&p.clips[i].text) }
            }
        }
        let done: (Bool) -> Void = { if !$0 { model.commitLive() } }
        InspectorSection("Transform", action: centred ? nil : ("Reset", {
            model.mutate { p in
                if let i = p.index(of: c.id) {
                    p.clips[i].text.x = 0.5
                    p.clips[i].text.y = 0.5
                }
            }
        }), collapsedByDefault: true, marked: !centred) {
            ParamRow(icon: .symbol("arrow.left.and.right"), label: "X", value: (c.text.x - 0.5) * w, range: -w / 2...w / 2,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in update { $0.x = 0.5 + v.rounded() / w } })
            ParamRow(icon: .symbol("arrow.up.and.down"), label: "Y", value: (c.text.y - 0.5) * h, range: -h / 2...h / 2,
                     format: { "\(Int($0.rounded()))" }, onEditing: done,
                     onChange: { v in update { $0.y = 0.5 + v.rounded() / h } })
        }
    }
}

// MARK: - Building blocks

/// A titled group of rows. Click the header to fold it away; the choice is remembered per section.
private struct InspectorSection<Content: View>: View {
    let title: String
    let action: (String, () -> Void)?
    /// Shows a dot beside the title while folded, so a changed section isn't hidden silently.
    let marked: Bool
    @ViewBuilder let content: Content
    @AppStorage private var collapsed: Bool
    @State private var hovering = false

    init(_ title: String, action: (String, () -> Void)? = nil, collapsedByDefault: Bool = false, marked: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.marked = marked
        self.content = content()
        _collapsed = AppStorage(wrappedValue: collapsedByDefault, "inspector.collapsed.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { collapsed.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: 8)
                        Text(title.uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .kerning(1)
                        if marked && collapsed {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(hovering ? Theme.textDim : Theme.textFaint)
                    .frame(height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                if let action, !collapsed {
                    TextLink(title: action.0, action: action.1)
                }
            }
            if !collapsed { content }
        }
    }
}

private struct TextLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.accent : Theme.textDim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Slim slider: accent fill, white knob.
struct ThinSlider: View {
    /// Normalised 0...1.
    let value: Double
    let onEditing: (Bool) -> Void
    let onChange: (Double) -> Void
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 13
            let travel = max(1, geo.size.width - knob)
            let x = CGFloat(min(1, max(0, value))) * travel
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 3)
                Capsule().fill(Theme.accent).frame(width: x + knob / 2, height: 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging || hovering ? 1.12 : 1)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            onEditing(true)
                        }
                        onChange(Double(min(1, max(0, (v.location.x - knob / 2) / travel))))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditing(false)
                    }
            )
        }
        .frame(height: 20)
    }
}

private enum RowIcon {
    case symbol(String)
    case fadeIn
    case fadeOut
}

private struct RowIconView: View {
    let icon: RowIcon

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 11, weight: .medium))
        case .fadeIn:
            HStack(spacing: 1) {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                Capsule().frame(width: 1.5, height: 10)
            }
        case .fadeOut:
            HStack(spacing: 1) {
                Capsule().frame(width: 1.5, height: 10)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
            }
        }
    }
}

/// One parameter: icon, name, slider, typed value, and an optional trailing control.
private struct ParamRow: View {
    let icon: RowIcon
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var logarithmic = false
    let format: (Double) -> String
    let onEditing: (Bool) -> Void
    let onChange: (Double) -> Void
    var trailing: AnyView?

    @State private var text = ""
    @State private var cancelled = false
    @FocusState private var focused: Bool

    private var normalised: Double {
        let v = min(max(value, range.lowerBound), range.upperBound)
        if logarithmic { return (log(v) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound)) }
        return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func denormalise(_ n: Double) -> Double {
        if logarithmic { return exp(log(range.lowerBound) + n * (log(range.upperBound) - log(range.lowerBound))) }
        return range.lowerBound + n * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        HStack(spacing: 8) {
            RowIconView(icon: icon)
                .foregroundStyle(Theme.textDim)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .frame(width: 52, alignment: .leading)
            ThinSlider(value: normalised, onEditing: onEditing) { onChange(denormalise($0)) }
            // Always a text field, so Tab moves to the next row's value like any form. Return or leaving the
            // field applies what was typed; Esc puts the value back.
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { focused = false }
                .onExitCommand {
                    cancelled = true
                    focused = false
                }
                .onChange(of: focused) { _, isFocused in
                    if isFocused {
                        cancelled = false
                    } else {
                        if !cancelled { commit() }
                        text = format(value)
                    }
                }
                .onChange(of: value) { _, v in
                    if !focused { text = format(v) }
                }
                .onAppear { text = format(value) }
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 5)
            .frame(width: 60, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent.opacity(focused ? 0.9 : 0)))
            // The whole box is the click target, not just the digits.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            if let trailing { trailing }
        }
        .frame(height: 28)
    }

    /// Reads the number out of whatever is in the field ("100%", "0.50s", "−18.8 dB" all work).
    private func commit() {
        guard text != format(value) else { return }
        let cleaned = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
            .filter { "0123456789.-".contains($0) }
        if let v = Double(cleaned) {
            onEditing(true)
            onChange(min(max(v, range.lowerBound), range.upperBound))
            onEditing(false)
        }
    }
}

/// Dropdown showing the current fade shape as a small drawing.
private struct CurveMenu: View {
    let selection: FadeCurve
    let rising: Bool
    let active: Bool
    let onPick: (FadeCurve) -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(FadeCurve.allCases, id: \.self) { curve in
                // A toggle so the current one gets the menu's checkmark; the drawing shows the shape.
                Toggle(isOn: Binding(get: { curve == selection }, set: { _ in onPick(curve) })) {
                    Label {
                        Text(curve.label)
                    } icon: {
                        Image(nsImage: Self.glyph(curve, rising: rising))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                CurveGlyph(curve: selection, rising: rising, color: active ? Theme.accent : Theme.textDim)
                    .frame(width: 20, height: 12)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(width: 48, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(selection.label)
    }

    /// The curve drawn as a small template image, for the menu items.
    static func glyph(_ curve: FadeCurve, rising: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 13)
        let image = NSImage(size: size, flipped: false) { r in
            let path = NSBezierPath()
            for i in 0...24 {
                let x = Double(i) / 24
                let y = curve.apply(rising ? x : 1 - x)
                let pt = NSPoint(x: 1.5 + CGFloat(x) * (r.width - 3), y: 1.5 + CGFloat(y) * (r.height - 3))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private struct CurveGlyph: View {
    let curve: FadeCurve
    let rising: Bool
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for i in 0...20 {
                let x = Double(i) / 20
                let y = curve.apply(rising ? x : 1 - x)
                let pt = CGPoint(x: 1 + CGFloat(x) * (size.width - 2), y: 1 + (1 - CGFloat(y)) * (size.height - 2))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct Chip: View {
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(active ? Theme.accent : (hovering ? Theme.text : Theme.textDim))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : Theme.field)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuField<Content: View>: View {
    let label: String
    var symbol: String?
    var height: CGFloat = 28
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
    }
}

/// Font family chooser: a field showing the current font that opens a searchable list, each name
/// drawn in its own face. Type to filter; Return picks the first match.
private struct FontPicker: View {
    let selection: String
    let onPick: (String) -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 8) {
                Text(selection.isEmpty ? "System" : selection)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .leading) {
            FontList(selection: selection) { family in
                onPick(family)
                open = false
            }
        }
    }
}

private struct FontList: View {
    let selection: String
    let onPick: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private static let families = NSFontManager.shared.availableFontFamilies

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = [""] + Self.families
        guard !q.isEmpty else { return all }
        return all.filter { ($0.isEmpty ? "System" : $0).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textFaint)
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { if let first = matches.first { onPick(first) } }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches, id: \.self) { family in
                            FontRow(family: family, selected: family == selection) { onPick(family) }
                                .id(family)
                        }
                        if matches.isEmpty {
                            Text("No fonts match").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).padding(12)
                        }
                    }
                    .padding(4)
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(width: 260, height: 360)
        .background(Theme.panel)
        .onAppear { focused = true }
    }
}

private struct FontRow: View {
    let family: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(family.isEmpty ? "System" : family)
                    .font(family.isEmpty ? .system(size: 14) : .custom(family, size: 14))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ColorField: View {
    let color: RGBA
    let onChange: (RGBA) -> Void

    var body: some View {
        ColorPicker("", selection: Binding(get: { color.color }, set: { onChange(RGBA($0)) }), supportsOpacity: false)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Width × height entry for a custom sequence size. Return or clicking away applies, Esc reverts.
private struct FrameSizeFields: View {
    let width: Int
    let height: Int
    let apply: (Int, Int) -> Void
    @State private var w = ""
    @State private var h = ""
    @FocusState private var focus: Int?

    var body: some View {
        HStack(spacing: 6) {
            field($w, tag: 0)
            Text("×").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            field($h, tag: 1)
        }
        .onAppear(perform: sync)
        .onChange(of: width) { _, _ in sync() }
        .onChange(of: height) { _, _ in sync() }
        .onChange(of: focus) { _, new in
            if new == nil { commit() }
        }
    }

    private func field(_ text: Binding<String>, tag: Int) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.text)
            .focused($focus, equals: tag)
            .onSubmit {
                commit()
                focus = nil
            }
            .onExitCommand {
                sync()
                focus = nil
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(focus == tag ? 0.9 : 0)))
            // The whole box is the click target, not just the line of text.
            .contentShape(Rectangle())
            .onTapGesture { focus = tag }
    }

    private func sync() {
        w = String(width)
        h = String(height)
    }

    private func commit() {
        guard let nw = Int(w.filter(\.isNumber)), let nh = Int(h.filter(\.isNumber)) else { return sync() }
        // Encoders need even dimensions.
        let cw = min(8192, max(16, nw / 2 * 2)), ch = min(8192, max(16, nh / 2 * 2))
        if cw != width || ch != height { apply(cw, ch) } else { sync() }
    }
}

/// A tint wheel: drag the puck toward a colour to push that tonal range toward it. Double-click resets.
private struct ColorWheel: View {
    let title: String
    let point: WheelPoint
    let onChange: (WheelPoint) -> Void
    let onEnd: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    private static let size: CGFloat = 78

    var body: some View {
        let s = Self.size
        let active = point.x != 0 || point.y != 0
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(Theme.field)
                // Hue ring: red at 0°, green at 120°, blue at 240°, matching the direction the puck tints.
                Circle()
                    .strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, Color(red: 1, green: 0, blue: 1), .red], center: .center), lineWidth: 3)
                    .opacity(hovering || dragging ? 0.95 : 0.6)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: s - 14)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: s - 14, height: 1)
                Circle()
                    .fill(active ? Theme.accent : Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                    .frame(width: dragging ? 13 : 11, height: dragging ? 13 : 11)
                    .offset(x: CGFloat(point.x) * (s / 2 - 8), y: CGFloat(point.y) * (s / 2 - 8))
            }
            .frame(width: s, height: s)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        dragging = true
                        var x = Double((v.location.x - s / 2) / (s / 2 - 8))
                        var y = Double((v.location.y - s / 2) / (s / 2 - 8))
                        let m = (x * x + y * y).squareRoot()
                        if m > 1 { x /= m; y /= m }
                        // A small dead zone makes it easy to return to exactly neutral.
                        if m < 0.06 { x = 0; y = 0 }
                        onChange(WheelPoint(x: (x * 100).rounded() / 100, y: (y * 100).rounded() / 100))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                onChange(WheelPoint())
                onEnd()
            })
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(active ? Theme.text : Theme.textDim)
        }
        .frame(maxWidth: .infinity)
        .help("Drag to tint \(title.lowercased()). Double-click to reset.")
    }
}
