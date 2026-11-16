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
        return [("Source", nil)] + scaled.map { ($0.0, Optional($0.1)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Export")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(model.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            .padding(.bottom, 18)

            HStack(spacing: 10) {
                FormatCard(symbol: "film", title: "Video", detail: "MP4", selected: settings.format == .mp4) { settings.format = .mp4 }
                FormatCard(symbol: "waveform", title: "Audio", detail: "WAV", selected: settings.format == .wav) { settings.format = .wav }
            }
            .padding(.bottom, 14)

            VStack(spacing: 0) {
                if settings.format == .mp4 {
                    row("Resolution") {
                        Segmented(options: heights.map(\.0), label: { $0 },
                                  selection: Binding(
                                    get: { heights.first { $0.1 == settings.height }?.0 ?? "Source" },
                                    set: { name in settings.height = heights.first { $0.0 == name }?.1 }
                                  ))
                    }
                    Hairline()
                    row("Codec") {
                        Segmented(options: ExportSettings.Codec.allCases, label: { $0.rawValue }, selection: $settings.codec)
                    }
                    Hairline()
                    row("Quality") {
                        Segmented(options: ExportSettings.Quality.allCases, label: { $0 == .high ? "High" : "Web" }, selection: $settings.quality)
                    }
                    Hairline()
                    row("Audio") {
                        Segmented(options: [true, false], label: { $0 ? "Included" : "None" }, selection: $settings.includeAudio)
                    }
                } else {
                    row("Format") {
                        Text("48 kHz · 24-bit · Stereo")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            .padding(.bottom, 18)

            footer
        }
        .padding(24)
        .frame(width: 500)
        .background(Theme.raised)
        .preferredColorScheme(.dark)
        .onAppear { exporter.reset() }
        .onExitCommand(perform: escape)
    }

    private var summary: String {
        if settings.format == .wav { return Timecode.short(model.project.duration) }
        let size = settings.renderSize(for: model.project)
        let fps = model.project.fps
        let bits = Double(settings.videoBitrate(size: size, fps: fps)) + (settings.includeAudio ? 256_000 : 0)
        let megabytes = bits * model.project.duration / 8 / 1_000_000
        let sizeText = megabytes >= 1000 ? String(format: "%.1f GB", megabytes / 1000) : String(format: "%.0f MB", max(1, megabytes))
        return "\(Int(size.width)) × \(Int(size.height))  ·  \(InspectorView.fpsLabel(fps))  ·  ~\(sizeText)"
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .frame(width: 78, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func escape() {
        if exporter.state == .running { exporter.cancel() } else { model.showExport = false }
    }

    @ViewBuilder private var footer: some View {
        switch exporter.state {
        case .running:
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Theme.accent).frame(width: max(6, geo.size.width * exporter.progress))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("Exporting  \(Int(exporter.progress * 100))%")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    PillButton(title: "Cancel", prominent: false, shortcut: .cancelAction) { exporter.cancel() }
                }
            }
        case .done(let url):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: 0x3DDC97))
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                PillButton(title: "Show in Finder", prominent: false) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                PillButton(title: "Done", prominent: true, shortcut: .defaultAction) { model.showExport = false }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xFF7A6B))
                    .fixedSize(horizontal: false, vertical: true)
                buttons
            }
        case .idle:
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textFaint)
            Spacer()
            PillButton(title: "Cancel", prominent: false, shortcut: .cancelAction) { model.showExport = false }
            PillButton(title: "Export", prominent: true, shortcut: .defaultAction) { start() }
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

private struct FormatCard: View {
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.textDim)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Theme.accent.opacity(0.16) : Color.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.07 : (hovering ? 0.06 : 0.03))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.9) : Color.white.opacity(hovering ? 0.16 : 0.07), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PillButton: View {
    let title: String
    let prominent: Bool
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Theme.text)
                .padding(.horizontal, 15)
                .frame(height: 28)
                .background(
                    Capsule().fill(prominent ? Theme.accent.opacity(hovering ? 1 : 0.9) : (hovering ? Color.white.opacity(0.14) : Color.white.opacity(0.08)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.3)))
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
                        .fill(selected ? Color.white.opacity(0.15) : (hovering ? Color.white.opacity(0.05) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
