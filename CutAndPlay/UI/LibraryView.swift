import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var media: MediaStore
    @State private var dropTargeted = false
    @State private var search = ""

    private var shown: [MediaAsset] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.project.assets }
        return model.project.assets.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        // Library items used by whatever is selected on the timeline.
        let inSelection = Set(model.selection.compactMap { model.project.clip($0)?.assetID })
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Media")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if model.importCount > 0 {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                }
                Spacer()
                AddButton(model: model, symbol: "textformat", payload: .text, help: "Text: click to add at the playhead, or drag to the timeline")
                AddButton(model: model, symbol: "solid", payload: .solid, help: "Solid: click to add at the playhead, or drag to the timeline")
                IconButton(symbol: "square.and.arrow.down", size: 26, help: "Import Media (⌘I)") { model.showImportPanel() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.project.assets.isEmpty {
                        EmptyLibrary(targeted: dropTargeted) { model.showImportPanel() }
                    } else {
                        SearchField(text: $search)
                        VStack(spacing: 3) {
                            ForEach(shown) { asset in
                                AssetRow(model: model, media: media, asset: asset, offline: media.isOffline(asset), selected: inSelection.contains(asset.id))
                            }
                        }
                        if shown.isEmpty {
                            Text("No media matches “\(search)”")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textFaint)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Theme.accent.opacity(dropTargeted ? 0.9 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { model.importFiles($0) }
            return true
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.textFaint)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent.opacity(focused ? 0.9 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// A library item's picture. Moving the mouse across a video's thumbnail scrubs through it.
private struct MediaThumb: View {
    @ObservedObject var media: MediaStore
    let asset: MediaAsset
    let offline: Bool
    var compact = false
    @State private var scrub: CGFloat?
    @State private var frame: CGImage?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.5)
                if let frame, scrub != nil {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else if let poster = media.posters[asset.id] {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height).clipped()
                } else {
                    Image(systemName: asset.kind == .audio ? "waveform" : asset.kind == .image ? "photo" : "film")
                        .font(.system(size: compact ? 13 : 20, weight: .regular))
                        .foregroundStyle(asset.kind == .audio ? Color(nsColor: Theme.NS.audio) : Theme.textFaint)
                        .frame(width: g.size.width, height: g.size.height)
                }
                if offline {
                    Color.black.opacity(0.6)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        .frame(width: g.size.width, height: g.size.height)
                }
                if let scrub {
                    Rectangle().fill(Color.white).frame(width: 1.5, height: g.size.height).offset(x: scrub - 0.75)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard asset.kind == .video, !offline, asset.duration > 0 else { return }
                switch phase {
                case .active(let p):
                    let x = min(max(0, p.x), g.size.width)
                    scrub = x
                    // Quantise so nearby positions share cached frames.
                    let steps = 60.0
                    let t = min(asset.duration - 0.05, (Double(x / max(1, g.size.width)) * steps).rounded() / steps * asset.duration)
                    media.scrubFrame(asset: asset.id, time: max(0, t)) { img in
                        if scrub != nil { frame = img }
                    }
                case .ended:
                    scrub = nil
                    frame = nil
                }
            }
        }
    }
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

private struct EmptyLibrary: View {
    let targeted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 18, weight: .medium))
                Text("Drop media")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(hovering || targeted ? Theme.text : Theme.textFaint)
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(hovering || targeted ? Theme.accent : Color.white.opacity(0.14))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Header button for text or a solid: click to add one at the playhead, or drag it to the timeline.
private struct AddButton: View {
    let model: EditorModel
    let symbol: String
    let payload: DragPayload
    let help: String
    @State private var hovering = false

    var body: some View {
        Group {
            if symbol == "solid" {
                SolidIcon().frame(width: 17, height: 13)
            } else {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            }
        }
            .foregroundStyle(hovering ? Theme.text : Theme.textDim)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { model.addAtPlayhead(payload) }
            .onDrag {
                model.dragPayload = payload
                return NSItemProvider(object: ("cutandplay:" + (payload == .text ? "text" : "solid")) as NSString)
            }
            .help(help)
    }
}

/// Shared behaviour for a library item: double-click adds it, drag it out, right-click for more.
private struct AssetActions: ViewModifier {
    let model: EditorModel
    let asset: MediaAsset
    let offline: Bool

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { model.addAtPlayhead(.asset(asset.id)) }
            .onDrag {
                model.dragPayload = .asset(asset.id)
                return NSItemProvider(object: ("cutandplay:" + asset.id.uuidString) as NSString)
            }
            .contextMenu {
                if offline {
                    Button("Locate…") { model.locate(asset.id) }
                    Divider()
                }
                Button("Add to Timeline") { model.addAtPlayhead(.asset(asset.id)) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)]) }
                Divider()
                Button("Remove") { model.removeAsset(asset.id) }
            }
    }
}

private struct AssetRow: View {
    let model: EditorModel
    let media: MediaStore
    let asset: MediaAsset
    let offline: Bool
    /// Used by a clip selected on the timeline.
    let selected: Bool
    @State private var hovering = false

    private var detail: String {
        var parts: [String] = []
        if asset.kind != .image { parts.append(Timecode.short(asset.duration)) }
        if asset.width > 0 { parts.append("\(asset.width)×\(asset.height)") }
        if asset.kind == .audio { parts.append("Audio") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        HStack(spacing: 9) {
            MediaThumb(media: media, asset: asset, offline: offline, compact: true)
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering || selected ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.85 : 0), lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(AssetActions(model: model, asset: asset, offline: offline))
    }
}
