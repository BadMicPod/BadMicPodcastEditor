import SwiftUI
import AppKit
import AVFoundation

/// Colours for the export sheet: a cool, slightly blue dark, a step apart from the editor chrome.
enum SheetStyle {
    static let background = Color(hex: 0x1B1D27)
    static let field = Color(hex: 0x272A36)
    static let fieldHover = Color(hex: 0x2F3340)
    static let fieldStroke = Color(hex: 0x3A3E4D)
    static let label = Color(hex: 0xB4B9C8)
    static let text = Color(hex: 0xF2F3F7)
    static let divider = Color.white.opacity(0.08)
    static let radius: CGFloat = 8
}

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @State private var failure: String?
    @State private var settings = ExportSettings()
    @State private var name = ""
    @State private var folder = URL(fileURLWithPath: NSHomeDirectory())
    @StateObject private var player = PreviewPlayer()
    @FocusState private var nameFocused: Bool

    private var heights: [(String, Int?)] {
        let p = model.project
        let vertical = p.height > p.width
        let base: [(String, Int)] = [("4K", 2160), ("1440p", 1440), ("1080p", 1080), ("720p", 720)]
        // For vertical frames the label names the short side.
        let scaled: [(String, Int?)] = base.map { item in
            let h = vertical ? Int((Double(item.1) * Double(p.height) / Double(p.width)).rounded()) : item.1
            let size = ExportSettings(height: h).renderSize(for: p)
            return ("\(item.0) (\(Int(size.width)) × \(Int(size.height)))", h)
        }
        return [("Source (\(p.width) × \(p.height))", nil)] + scaled
    }

    private var isVideo: Bool { settings.format == .mp4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SheetStyle.text)
                .padding(.bottom, 16)

            HStack(alignment: .center, spacing: 20) {
                form.frame(width: 284)
                Rectangle().fill(SheetStyle.divider).frame(width: 1)
                summaryColumn.frame(width: Self.previewWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)

            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .background(SheetStyle.background)
        .preferredColorScheme(.dark)
        .onAppear(perform: setUp)
        .onExitCommand(perform: escape)
        .onDisappear { player.stop() }
    }

    static let loudnessTargets: [(String, Double?)] = [
        ("As mixed", nil), ("−14 LUFS · web, YouTube", -14), ("−16 LUFS · podcasts", -16), ("−23 LUFS · broadcast", -23),
    ]

    static func loudnessLabel(_ v: Double?) -> String {
        guard let v else { return "As mixed" }
        return "\(Int(v)) LUFS".replacingOccurrences(of: "-", with: "−")
    }

    static let previewWidth: CGFloat = 288
    static let fieldHeight: CGFloat = 28

    // MARK: Left column

    private var form: some View {
        let h = Self.fieldHeight
        return VStack(spacing: 8) {
            row("Filename") {
                HStack(spacing: 0) {
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .fixedSize()
                        .focused($nameFocused)
                    Text("." + settings.fileExtension)
                        .padding(.leading, -4)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SheetStyle.text)
                .padding(.horizontal, 11)
                .frame(height: h)
                .sheetField(focused: nameFocused)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { nameFocused = true }
            }
            row("Location") {
                FolderButton(folder: folder, height: h, action: chooseFolder)
            }
            row("Format") {
                SheetMenu(label: isVideo ? "MP4 Video" : "WAV Audio", symbol: isVideo ? "film" : "waveform", height: h) {
                    Button("MP4 Video") { settings.format = .mp4 }
                    Button("WAV Audio") { settings.format = .wav }
                }
            }
            row("Loudness") {
                let on = !isVideo || settings.includeAudio
                SheetMenu(label: Self.loudnessLabel(settings.loudness), height: h) {
                    ForEach(Self.loudnessTargets, id: \.0) { item in
                        Button(item.0) { settings.loudness = item.1 }
                    }
                }
                .disabled(!on)
                .opacity(on ? 1 : 0.4)
            }
            if isVideo {
                row("Resolution") {
                    SheetMenu(label: heights.first { $0.1 == settings.height }?.0 ?? heights[0].0, height: h) {
                        ForEach(heights, id: \.0) { item in
                            Button(item.0) { settings.height = item.1 }
                        }
                    }
                }
                row("Codec") {
                    SheetMenu(label: settings.codec.rawValue, height: h) {
                        ForEach(ExportSettings.Codec.allCases, id: \.self) { codec in
                            Button(codec.rawValue) { settings.codec = codec }
                        }
                    }
                }
                row("Quality") {
                    SheetMenu(label: settings.quality == .high ? "High" : "Web", height: h) {
                        Button("High") { settings.quality = .high }
                        Button("Web") { settings.quality = .web }
                    }
                }
                row("Audio") {
                    HStack(spacing: 10) {
                        AccentSwitch(isOn: $settings.includeAudio)
                        Text("Include audio")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SheetStyle.text)
                        Spacer()
                    }
                    .frame(height: h)
                }
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(SheetStyle.label)
                .frame(width: 84, alignment: .leading)
            content()
        }
    }

    // MARK: Right column

    private var summaryColumn: some View {
        let p = model.project
        let size = settings.renderSize(for: p)
        let w = Self.previewWidth
        return VStack(alignment: .leading, spacing: 12) {
            PreviewPlayerBox(player: player, showsVideo: isVideo)
                .frame(width: w, height: (w * 9 / 16).rounded())

            // Spread edge to edge under the preview: first item flush left, last flush right.
            HStack(spacing: 0) {
                if isVideo {
                    stat("display", "\(Int(size.width)) × \(Int(size.height))")
                    Spacer(minLength: 8)
                    statDivider
                    Spacer(minLength: 8)
                    stat(nil, InspectorView.fpsLabel(p.fps))
                } else {
                    stat("waveform", "48 kHz · 24-bit")
                }
                Spacer(minLength: 8)
                statDivider
                Spacer(minLength: 8)
                stat("doc", estimatedSize)
            }
            .padding(.horizontal, 4)
        }
    }

    private var statDivider: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 13)
    }

    private func stat(_ symbol: String?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(SheetStyle.label)
            }
            Text(text).font(.system(size: 11.5)).foregroundStyle(SheetStyle.label).lineLimit(1)
        }
    }

    private var estimatedSize: String {
        let p = model.project
        let bits: Double
        if isVideo {
            let size = settings.renderSize(for: p)
            bits = Double(settings.videoBitrate(size: size, fps: p.fps)) + (settings.includeAudio ? 256_000 : 0)
        } else {
            bits = 48000 * 24 * 2
        }
        let megabytes = bits * p.duration / 8 / 1_000_000
        return megabytes >= 1000 ? String(format: "~%.1f GB", megabytes / 1000) : String(format: "~%.0f MB", max(1, megabytes))
    }

    // MARK: Actions

    private func setUp() {
        name = model.project.exportName ?? model.title
        if let dir = model.project.exportDir, FileManager.default.fileExists(atPath: dir) {
            folder = URL(fileURLWithPath: dir)
        } else {
            folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? folder
        }
        model.pause()
        player.load(model)
        // Don't open with the filename selected; it reads as an error state.
        DispatchQueue.main.async { nameFocused = false }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func escape() {
        model.showExport = false
    }

    private func start() {
        model.pause()
        player.pause()
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        if clean.isEmpty { clean = model.title }
        name = clean
        let url = folder.appendingPathComponent(clean + "." + settings.fileExtension)
        if FileManager.default.fileExists(atPath: url.path) {
            let alert = NSAlert()
            alert.messageText = "Replace “\(url.lastPathComponent)”?"
            alert.informativeText = "A file with this name already exists in \(folder.lastPathComponent)."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.commitLive()
        let p = model.project
        if settings.format == .wav && !p.clips.contains(where: { $0.kind == .audio }) {
            failure = "There's no audio on the timeline."
            return
        }
        model.setExportTarget(name: clean, directory: folder.path)
        // It runs in the background; the toolbar shows how it's going.
        model.exports.add(project: model.project, media: model.media, settings: settings, url: url)
        model.showExport = false
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xFF7A6B))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            PillButton(title: "Cancel", prominent: false, large: true, shortcut: .cancelAction) { model.showExport = false }
            PillButton(title: "Export", prominent: true, large: true, shortcut: .defaultAction) { start() }
                .disabled(model.project.duration <= 0)
        }
    }
}

private struct FolderButton: View {
    let folder: URL
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SheetStyle.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(hovering ? SheetStyle.text : SheetStyle.label)
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .sheetField(hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Choose where exports are saved")
    }
}

// MARK: - Preview player

/// A small independent player for the export sheet, so the timeline can be watched before exporting.
@MainActor
final class PreviewPlayer: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    private var startTime = CMTime.zero
    private var endObserver: NSObjectProtocol?

    func load(_ model: EditorModel) {
        let p = model.project
        let scale = min(1, 960 / CGFloat(max(p.width, p.height)))
        let size = CGSize(width: max(2, (CGFloat(p.width) * scale / 2).rounded() * 2),
                          height: max(2, (CGFloat(p.height) * scale / 2).rounded() * 2))
        guard let built = CompositionBuilder.build(project: p, media: model.media, renderSize: size) else { return }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        player.actionAtItemEnd = .pause
        player.replaceCurrentItem(with: item)
        // Open on the frame under the playhead; playing from the very end starts over.
        let t = min(max(0, model.playhead), max(0, built.duration - 1 / p.fps))
        startTime = CompositionBuilder.time(t)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        isReady = true
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    func toggle() {
        guard isReady else { return }
        if isPlaying {
            pause()
        } else {
            player.playImmediately(atRate: 1)
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        pause()
        player.replaceCurrentItem(with: nil)
        isReady = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct PreviewPlayerBox: View {
    @ObservedObject var player: PreviewPlayer
    let showsVideo: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black
            if showsVideo {
                PlayerLayerView(player: player.player)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.textFaint)
            }
            if !player.isPlaying || hovering {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .scaleEffect(hovering ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(hovering ? 0.28 : 0.14)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { player.toggle() }
        .help("Play preview")
    }
}

struct PillButton: View {
    let title: String
    let prominent: Bool
    var large = false
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, large ? 18 : 15)
                .frame(height: 28)
                .background(
                    Capsule().fill(prominent
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(large ? (hovering ? Color(hex: 0x363A48) : Color(hex: 0x2B2E3A)) : Color.white.opacity(hovering ? 0.14 : 0.08)))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0 : 0.05)))
                .brightness(prominent && hovering ? 0.05 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// The rounded, softly outlined field used throughout the export sheet.
    func sheetField(hovering: Bool = false, focused: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: SheetStyle.radius, style: .continuous).fill(hovering ? SheetStyle.fieldHover : SheetStyle.field))
            .overlay(RoundedRectangle(cornerRadius: SheetStyle.radius, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.85) : SheetStyle.fieldStroke, lineWidth: 1))
    }
}

/// Dropdown styled for the export sheet.
private struct SheetMenu<Content: View>: View {
    let label: String
    var symbol: String?
    var height: CGFloat = 30
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
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(SheetStyle.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(SheetStyle.text.opacity(0.85))
            }
            .padding(.horizontal, 11)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .sheetField(hovering: hovering)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
    }
}

/// Orange on/off switch with a white knob.
private struct AccentSwitch: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Theme.accent : Color(hex: 0x3A3E4D))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                .padding(2)
        }
        .frame(width: 34, height: 20)
        .brightness(hovering ? 0.06 : 0)
        .animation(.easeOut(duration: 0.14), value: isOn)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture { isOn.toggle() }
    }
}
