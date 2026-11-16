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
                                  let all = model.project.linked(ids)
                                  speedOrigin = model.project.clips.filter { all.contains($0.id) }
                              } else {
                                  speedOrigin = nil
                                  model.commitLive()
                              }
                          },
                          onChange: { applySpeed($0 / 100, ids: ids) })
                HStack(spacing: 5) {
                    ForEach([50, 100, 200, 400, 1000, 3000], id: \.self) { pct in
                        Chip(label: pct >= 1000 ? "\(pct / 100)×" : "\(pct)%", active: abs(first.speed * 100 - Double(pct)) < 0.5) {
                            model.setSpeed(Double(pct) / 100)
                        }
                    }
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
            for o in origin {
                if let i = p.index(of: o.id) { p.clips[i] = o }
            }
            p.setSpeed(ids: Set(origin.map(\.id)), speed: speed)
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
            SliderRow(caption: "Out", value: first.fadeOut, range: 0...maxFade, format: { String(format: "%.2fs", $0) },
                      onEditing: { if !$0 { model.commitLive() } },
                      onChange: { v in
                          model.live(autoCommit: false) { p in
                              for i in p.clips.indices where ids.contains(p.clips[i].id) {
                                  p.clips[i].fadeOut = min(p.snapFrame(v), p.clips[i].duration - p.clips[i].fadeIn)
                              }
                          }
                      })
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
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { editing = false }
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
