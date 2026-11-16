import SwiftUI
import AppKit

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var exporter: Exporter
    @State private var settings = ExportSettings()

    private var heights: [(String, Int?)] {
        let p = model.project
        let vertical = p.height > p.width
        let base: [(String, Int)] = [("4K", 2160), ("1440p", 1440), ("1080p", 1080), ("720p", 720)]
        // For vertical frames the label names the short side.
        let scaled = base.map { ($0.0, vertical ? Int((Double($0.1) * Double(p.height) / Double(p.width)).rounded()) : $0.1) }
        return [("Sequence", nil)] + scaled.map { ($0.0, Optional($0.1)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Segmented(options: ExportSettings.Format.allCases, label: { $0 == .mp4 ? "Video · MP4" : "Audio · WAV" }, selection: $settings.format)

            if settings.format == .mp4 {
                row("Resolution") {
                    Segmented(options: heights.map(\.0), label: { $0 },
                              selection: Binding(
                                get: { heights.first { $0.1 == settings.height }?.0 ?? "Sequence" },
                                set: { name in settings.height = heights.first { $0.0 == name }?.1 }
                              ))
                }
                row("Codec") {
                    Segmented(options: ExportSettings.Codec.allCases, label: { $0.rawValue }, selection: $settings.codec)
                }
                row("Quality") {
                    Segmented(options: ExportSettings.Quality.allCases, label: { $0.rawValue }, selection: $settings.quality)
                }
                row("Audio") {
                    Segmented(options: [true, false], label: { $0 ? "On" : "Off" }, selection: $settings.includeAudio)
                }
            }

            Text(summary)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textDim)

            footer
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.raised)
        .preferredColorScheme(.dark)
        .onAppear { exporter.reset() }
    }

    private var summary: String {
        if settings.format == .wav { return "48 kHz · 24-bit · Stereo" }
        let size = settings.renderSize(for: model.project)
        let mbps = Double(settings.videoBitrate(size: size, fps: model.project.fps)) / 1_000_000
        return "\(Int(size.width)) × \(Int(size.height)) · \(InspectorView.fpsLabel(model.project.fps)) · \(String(format: "%.0f", mbps)) Mbps"
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }

    @ViewBuilder private var footer: some View {
        switch exporter.state {
        case .running:
            HStack(spacing: 12) {
                ProgressView(value: exporter.progress)
                    .tint(Theme.accent)
                Text("\(Int(exporter.progress * 100))%")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                    .frame(width: 38, alignment: .trailing)
                PillButton(title: "Cancel", prominent: false) { exporter.cancel() }
            }
        case .done(let url):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                PillButton(title: "Show in Finder", prominent: false) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                PillButton(title: "Done", prominent: true) { model.showExport = false }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: 0xFF7A6B))
                    .fixedSize(horizontal: false, vertical: true)
                buttons
            }
        case .idle:
            buttons
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            PillButton(title: "Cancel", prominent: false) { model.showExport = false }
                .keyboardShortcut(.cancelAction)
            PillButton(title: "Export", prominent: true) { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.project.duration <= 0)
        }
    }

    private func start() {
        model.pause()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.title + "." + settings.fileExtension
        panel.allowedContentTypes = [settings.format == .mp4 ? .mpeg4Movie : .wav]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.commitLive()
        exporter.start(project: model.project, media: model.media, settings: settings, url: url)
    }
}

struct PillButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Theme.text)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(
                    Capsule().fill(prominent ? Theme.accent.opacity(hovering ? 1 : 0.9) : (hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.08)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

struct Segmented<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                SegmentButton(title: label(option), selected: option == selection) { selection = option }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
    }
}

private struct SegmentButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.text : (hovering ? Theme.text : Theme.textDim))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.14) : (hovering ? Color.white.opacity(0.05) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
