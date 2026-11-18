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
                Text("MEDIA")
                    .font(Theme.label())
                    .kerning(1.6)
                    .foregroundStyle(Theme.textDim)
                if model.importCount > 0 {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                }
                Spacer()
                AddButton(model: model, symbol: "textformat", payload: .text, help: "Text: click to add at the playhead, or drag to the timeline")
                AddButton(model: model, symbol: "solid", payload: .solid, help: "Solid: click to add at the playhead, or drag to the timeline")
                IconButton(symbol: "square.and.arrow.down", size: 26, help: "Import Media (⌘I)") { model.showImportPanel() }
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.project.assets.isEmpty {
                        SearchField(text: $search)
                        Text("Imported media\nappears here")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textFaint)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    } else {
                        SearchField(text: $search)
                        let order = shown.map(\.id)
                        VStack(spacing: 3) {
                            ForEach(shown) { asset in
                                AssetRow(model: model, media: media, asset: asset, offline: media.isOffline(asset), selected: inSelection.contains(asset.id),
                                         picked: model.mediaSelection.contains(asset.id), pickedCount: model.mediaSelection.count,
                                         matchesSequence: model.sequenceMatches(asset))
                                    // A click picks it (⇧ for a range, ⌘ to add or take away); a double-click adds it.
                                    .simultaneousGesture(TapGesture().onEnded { model.clickMedia(asset.id, in: order) })
                            }
                        }
                        if shown.isEmpty {
                            Text("No media matches “\(search)”")
                                .font(.system(size: 11.5))
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
        .background(Theme.panel).panelTopLight()
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
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.text.opacity(focused ? 0.85 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// A library item's picture. Moving the mouse across a video's thumbnail scrubs through it.
private struct MediaThumb: View {
    @ObservedObject var media: MediaStore
    /// Where to show the hovered frame full size; nil keeps scrubbing to the thumbnail.
    var preview: SourcePreviewState?
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
                        .foregroundStyle(asset.kind == .audio ? Theme.textDim : Theme.textFaint)
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
                    // The main viewer follows the mouse exactly, not in steps.
                    let exact = min(asset.duration - 0.02, Double(x / max(1, g.size.width)) * asset.duration)
                    preview?.show(asset, at: max(0, exact), media: media)
                case .ended:
                    scrub = nil
                    frame = nil
                    preview?.clear()
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

private struct AddButton: View {
    let model: EditorModel
    let symbol: String
    let payload: DragPayload
    let help: String
    @State private var hovering = false

    var body: some View {
        Glyph(symbol: symbol, size: 12)
            .foregroundStyle(hovering ? Theme.text : Theme.textDim)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onTapGesture { model.addAtPlayhead(payload) }
            .background(MagicAnchor(key: payload == .text ? "addText" : "addSolid"))
            .onDrag {
                model.dragPayload = payload
                return NSItemProvider(object: ("editroom:" + (payload == .text ? "text" : "solid")) as NSString)
            }
            .help(help)
    }
}

/// Shared behaviour for a library item: double-click adds it, drag it out, right-click for more.
private struct AssetActions: ViewModifier {
    let model: EditorModel
    let asset: MediaAsset
    let offline: Bool
    let picked: Bool
    let pickedCount: Int
    let matchesSequence: Bool

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { model.addAtPlayhead(.asset(asset.id)) }
            .onDrag {
                model.dragPayload = .asset(asset.id)
                return NSItemProvider(object: ("editroom:" + asset.id.uuidString) as NSString)
            }
            .contextMenu {
                if offline {
                    Button("Locate…") { model.locate(asset.id) }
                    Divider()
                }
                Button("Add to Timeline") { model.addAtPlayhead(.asset(asset.id)) }
                if asset.kind == .video {
                    Button("Match Sequence to Clip") { model.matchSequence(to: asset) }
                        .disabled(matchesSequence)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)]) }
                Divider()
                // The picked items when this is one of them; otherwise just this one.
                if picked, pickedCount > 1 {
                    Button("Delete \(pickedCount) Items") { model.removeAssets(model.mediaSelection) }
                } else {
                    Button("Delete") { model.removeAssets([asset.id]) }
                }
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
    /// Picked in the Media panel.
    let picked: Bool
    let pickedCount: Int
    /// The sequence already has this video's size and rate. Passed in (rather than read from the
    /// model in the menu) so the row, and its menu, update when the sequence changes.
    let matchesSequence: Bool
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
            MediaThumb(media: media, preview: model.sourcePreview, asset: asset, offline: offline, compact: true)
                .frame(width: 64, height: 36)
                .background(MagicAnchor(key: asset.id.uuidString))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering || selected || picked ? Theme.text : Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(picked ? Color.white.opacity(0.12) : hovering ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(picked ? Color.white.opacity(0.18) : Color(hex: 0x3A3A3A).opacity(selected ? 1 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(AssetActions(model: model, asset: asset, offline: offline, picked: picked, pickedCount: pickedCount,
                               matchesSequence: matchesSequence))
    }
}
