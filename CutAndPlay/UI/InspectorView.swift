import SwiftUI
import AppKit

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    @State private var speedOrigin: [Clip]?

    private var selected: [Clip] {
        model.project.clips.filter { model.selection.contains($0.id) }
    }

    var body: some View {
        let clips = selected
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title(clips))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if clips.isEmpty {
                        sequenceSection
                    } else {
                        clipSections(clips)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .background(Theme.panel)
    }

    private func title(_ clips: [Clip]) -> String {
        if clips.isEmpty { return "Sequence" }
        let groups = Set(clips.map { $0.linkID ?? $0.id })
        if groups.count == 1, let c = clips.first(where: { $0.kind != .audio }) ?? clips.first {
            return model.project.name(of: c)
        }
        return "\(clips.count) clips"
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

        if let first = sourced.first {
            InspectorSection("Speed") {
                SliderRow(value: first.speed * 100, range: 10...5000, logarithmic: true,
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
                if abs(first.speed - 1) > 0.001 {
                    Chip(label: "Reset to 100%", active: false) { model.setSpeed(1) }
                }
            }
        }

        if let first = audio.first {
            InspectorSection("Volume") {
                SliderRow(value: first.gainDB, range: -60...12, format: formatDB,
                          onEditing: { if !$0 { model.commitLive() } },
                          onChange: { v in
                              let ids = Set(audio.map(\.id))
                              model.live(autoCommit: false) { p in
                                  for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].gainDB = (v * 10).rounded() / 10 }
                              }
                          })
            }
        }

        if !visual.isEmpty { fadeSection(visual.count < clips.count ? "Video fade" : "Fade", visual) }
        if !audio.isEmpty { fadeSection(visual.isEmpty ? "Fade" : "Audio fade", audio) }

        if clips.count == 1, let c = clips.first {
            if c.kind == .text { textSection(c) }
            if c.kind == .solid {
                InspectorSection("Color") {
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
            p.setSpeed(ids: p.linked(ids), speed: speed)
        }
    }

    @ViewBuilder private func fadeSection(_ title: String, _ clips: [Clip]) -> some View {
        let ids = Set(clips.map(\.id))
        let first = clips[0]
        let maxFade = max(0.1, min(first.duration, 10))
        InspectorSection(title) {
            SliderRow(caption: "In", value: first.fadeIn, range: 0...maxFade, format: { String(format: "%.2fs", $0) },
                      onEditing: { if !$0 { model.commitLive() } },
                      onChange: { v in
                          model.live(autoCommit: false) { p in
                              for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                  p.clips[i].fadeIn = min(p.snapFrame(v), p.clips[i].duration - p.clips[i].fadeOut)
                              }
                          }
                      })
            CurvePicker(selection: first.inCurve, rising: true) { curve in
                model.mutate { p in
                    for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].fadeInCurve = curve }
                }
            }
            SliderRow(caption: "Out", value: first.fadeOut, range: 0...maxFade, format: { String(format: "%.2fs", $0) },
                      onEditing: { if !$0 { model.commitLive() } },
                      onChange: { v in
                          model.live(autoCommit: false) { p in
                              for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                  p.clips[i].fadeOut = min(p.snapFrame(v), p.clips[i].duration - p.clips[i].fadeIn)
                              }
                          }
                      })
            CurvePicker(selection: first.outCurve, rising: false) { curve in
                model.mutate { p in
                    for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].fadeOutCurve = curve }
                }
            }
        }
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
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            MenuField(label: c.text.fontName.isEmpty ? "System" : c.text.fontName) {
                Button("System") { update { $0.fontName = "" } }
                Divider()
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
                    Button(family) { update { $0.fontName = family } }
                }
            }
            HStack(spacing: 8) {
                Chip(label: "Bold", active: c.text.bold) { update { $0.bold.toggle() } }
                ColorField(color: c.text.color) { color in update { $0.color = color } }
            }
            SliderRow(caption: "Size", value: c.text.size, range: 12...600, logarithmic: true, format: { "\(Int($0.rounded()))" },
                      onEditing: { if !$0 { model.commitLive() } },
                      onChange: { v in update { $0.size = v.rounded() } })
            SliderRow(caption: "X", value: c.text.x * 100, range: 0...100, format: { "\(Int($0.rounded()))%" },
                      onEditing: { if !$0 { model.commitLive() } },
                      onChange: { v in update { $0.x = v / 100 } })
            SliderRow(caption: "Y", value: c.text.y * 100, range: 0...100, format: { "\(Int($0.rounded()))%" },
                      onEditing: { if !$0 { model.commitLive() } },
                      onChange: { v in update { $0.y = v / 100 } })
        }
    }
}

// MARK: - Building blocks

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.textFaint)
            content
        }
    }
}

private struct SliderRow: View {
    var caption: String?
    let value: Double
    let range: ClosedRange<Double>
    var logarithmic = false
    let format: (Double) -> String
    let onEditing: (Bool) -> Void
    let onChange: (Double) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var sliderValue: Binding<Double> {
        Binding(
            get: {
                let v = min(max(value, range.lowerBound), range.upperBound)
                return logarithmic ? log(v) : v
            },
            set: { onChange(logarithmic ? exp($0) : $0) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 26, alignment: .leading)
            }
            Slider(value: sliderValue,
                   in: logarithmic ? log(range.lowerBound)...log(range.upperBound) : range,
                   onEditingChanged: onEditing)
                .controlSize(.mini)
                .tint(Theme.accent)
            Group {
                if editing {
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused, editing { commit() }
                        }
                } else {
                    Text(format(value))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            text = String(format: "%g", (value * 100).rounded() / 100)
                            editing = true
                            focused = true
                        }
                }
            }
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6)
            .frame(width: 62, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
        }
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }
        if let v = Double(cleaned) {
            onEditing(true)
            onChange(min(max(v, range.lowerBound), range.upperBound))
            onEditing(false)
        }
        editing = false
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
                .padding(.horizontal, 7)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : Theme.field)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack {
                Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent.opacity(focus == tag ? 0.9 : 0)))
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

/// Four small curve thumbnails for choosing a fade shape.
private struct CurvePicker: View {
    let selection: FadeCurve
    let rising: Bool
    let onPick: (FadeCurve) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 29, height: 1)
            ForEach(FadeCurve.allCases, id: \.self) { curve in
                CurveChip(curve: curve, rising: rising, active: curve == selection) { onPick(curve) }
            }
        }
    }
}

private struct CurveChip: View {
    let curve: FadeCurve
    let rising: Bool
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Canvas { ctx, size in
                let inset: CGFloat = 5
                let w = size.width - inset * 2, h = size.height - inset * 2
                var path = Path()
                for i in 0...20 {
                    let x = Double(i) / 20
                    let y = curve.apply(rising ? x : 1 - x)
                    let pt = CGPoint(x: inset + CGFloat(x) * w, y: inset + (1 - CGFloat(y)) * h)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(active ? Theme.accent : (hovering ? Theme.text : Theme.textDim)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : Theme.field)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(curve.label)
    }
}
