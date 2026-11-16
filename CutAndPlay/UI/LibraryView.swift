import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var media: MediaStore
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Media")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if model.importCount > 0 {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                }
                Spacer()
                IconButton(symbol: "plus", size: 26, help: "Import Media (⌘I)") { model.showImportPanel() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        GeneratorTile(symbol: "textformat", title: "Text", tint: Color(nsColor: Theme.NS.textClip), model: model, payload: .text)
                        GeneratorTile(symbol: "square.fill", title: "Solid", tint: Color(nsColor: Theme.NS.solid), model: model, payload: .solid)
                    }
                    if model.project.assets.isEmpty {
                        EmptyLibrary(targeted: dropTargeted) { model.showImportPanel() }
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.project.assets) { asset in
                                AssetTile(model: model, asset: asset, poster: media.posters[asset.id], offline: media.isOffline(asset))
                            }
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

private struct GeneratorTile: View {
    let symbol: String
    let title: String
    let tint: Color
    let model: EditorModel
    let payload: DragPayload
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(hovering ? 0.18 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.addAtPlayhead(payload) }
        .onDrag {
            model.dragPayload = payload
            return NSItemProvider(object: ("cutandplay:" + (payload == .text ? "text" : "solid")) as NSString)
        }
        .help("Drag to the timeline")
    }
}

private struct AssetTile: View {
    let model: EditorModel
    let asset: MediaAsset
    let poster: NSImage?
    let offline: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Color.black.opacity(0.5)
                if let poster {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: asset.kind == .audio ? "waveform" : asset.kind == .image ? "photo" : "film")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(asset.kind == .audio ? Color(nsColor: Theme.NS.audio) : Theme.textFaint)
                }
                if offline {
                    Color.black.opacity(0.6)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if asset.kind != .image {
                    Text(Timecode.short(asset.duration))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.65)))
                        .padding(4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(hovering ? Color.white.opacity(0.75) : Color.white.opacity(0.06), lineWidth: hovering ? 1.5 : 1)
            )
            Text(asset.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.addAtPlayhead(.asset(asset.id)) }
        .onDrag {
            model.dragPayload = .asset(asset.id)
            return NSItemProvider(object: ("cutandplay:" + asset.id.uuidString) as NSString)
        }
        .contextMenu {
            Button("Add to Timeline") { model.addAtPlayhead(.asset(asset.id)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)]) }
            Divider()
            Button("Remove") { model.removeAsset(asset.id) }
        }
    }
}
