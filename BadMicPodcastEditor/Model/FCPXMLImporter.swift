import Foundation

/// Imports an FCPXML (Final Cut Pro) edit into a project: media, cuts, timing and titles.
/// Premiere XML support can follow the same shape later.
@MainActor
enum FCPXMLImporter {
    static func importProject(from url: URL, model: EditorModel) async -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        guard let parsed = parser.result else { return false }

        // Probe each referenced file so the project has real media (dimensions, duration, audio).
        var assetMap: [String: MediaAsset] = [:]
        for (aid, info) in parsed.assets {
            let fileURL = URL(string: info.src) ?? URL(fileURLWithPath: info.src)
            if let asset = await model.media.importFile(fileURL) {
                assetMap[aid] = asset
            } else {
                // Fall back to a placeholder so the clip still lands, even if the file is offline.
                let asset = MediaAsset(id: UUID(), path: fileURL.path, name: info.name, kind: info.hasAudio ? .video : .video,
                                      duration: info.duration, width: parsed.width, height: parsed.height, fps: parsed.fps, hasAudio: info.hasAudio)
                assetMap[aid] = asset
            }
        }

        var project = Project()
        project.width = parsed.width
        project.height = parsed.height
        project.fps = parsed.fps
        project.assets = Array(assetMap.values)

        let vTrack = project.videoTracks.first?.id ?? UUID()
        let aTrack = project.audioTracks.first?.id ?? UUID()
        let titleTrack = project.videoTracks.count > 1 ? project.videoTracks[1].id : vTrack

        for item in parsed.spine {
            switch item {
            case .assetClip(let ref, let offset, let duration, let start):
                guard let asset = assetMap[ref] else { continue }
                let dur = duration > 0 ? duration : max(1.0 / project.fps, asset.duration - start)
                guard dur >= 1.0 / project.fps else { continue }
                var v = Clip(trackID: vTrack, kind: .video, assetID: asset.id, start: offset, duration: dur)
                v.sourceStart = start
                var clips: [Clip] = [v]
                if asset.hasAudio {
                    let link = UUID()
                    v.linkID = link
                    var au = Clip(trackID: aTrack, kind: .audio, assetID: asset.id, start: offset, duration: dur)
                    au.linkID = link
                    au.sourceStart = start
                    clips = [v, au]
                }
                project.clips.append(contentsOf: clips)
            case .title(let text, let offset, let duration):
                guard duration > 0 else { continue }
                var t = Clip(trackID: titleTrack, kind: .text, start: offset, duration: duration)
                t.text.string = text.isEmpty ? "Title" : text
                project.clips.append(t)
            case .gap:
                break
            }
        }

        model.load(project, url: nil)
        model.markDirty()
        return true
    }

    // MARK: Parsing

    private struct AssetInfo { var name: String; var src: String; var duration: Double; var hasAudio: Bool }
    private enum SpineItem { case assetClip(ref: String, offset: Double, duration: Double, start: Double)
                             case title(text: String, offset: Double, duration: Double)
                             case gap }

    private final class Parser: NSObject, XMLParserDelegate {
        var result: Parsed?
        struct Parsed {
            var width = 1920, height = 1080, fps = 30.0
            var assets: [String: AssetInfo] = [:]
            var spine: [SpineItem] = []
        }
        private var parsed = Parsed()
        private var stack: [String] = []
        private var text = ""
        private var currentTitleText = ""
        private var currentTitleOffset = 0.0
        private var currentTitleDuration = 0.0
        private var inTitle = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            stack.append(elementName)
            text = ""
            switch elementName {
            case "format":
                if let w = attributes["width"], let wi = Int(w) { parsed.width = wi }
                if let h = attributes["height"], let hi = Int(h) { parsed.height = hi }
                if let fd = attributes["frameDuration"] { parsed.fps = 1.0 / max(Self.seconds(fd), 1.0 / 30.0) }
            case "asset":
                if let id = attributes["id"], let src = attributes["src"] {
                    parsed.assets[id] = AssetInfo(
                        name: attributes["name"] ?? "Media",
                        src: src,
                        duration: attributes["duration"].map(Self.seconds) ?? 0,
                        hasAudio: attributes["hasAudio"] == "1")
                }
            case "asset-clip":
                let ref = attributes["ref"] ?? ""
                let offset = attributes["offset"].map(Self.seconds) ?? 0
                let duration = attributes["duration"].map(Self.seconds) ?? 0
                let start = attributes["start"].map(Self.seconds) ?? 0
                parsed.spine.append(.assetClip(ref: ref, offset: offset, duration: duration, start: start))
            case "gap":
                let offset = attributes["offset"].map(Self.seconds) ?? 0
                let duration = attributes["duration"].map(Self.seconds) ?? 0
                if duration > 0 { parsed.spine.append(.gap) }
                _ = offset
            case "title":
                inTitle = true
                currentTitleText = attributes["name"] ?? ""
                currentTitleOffset = attributes["offset"].map(Self.seconds) ?? 0
                currentTitleDuration = attributes["duration"].map(Self.seconds) ?? 0
            case "text":
                currentTitleText = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
            if inTitle, stack.last == "text" { currentTitleText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if elementName == "title" {
                parsed.spine.append(.title(text: currentTitleText.trimmingCharacters(in: .whitespacesAndNewlines),
                                           offset: currentTitleOffset, duration: currentTitleDuration))
                inTitle = false
            }
            if !stack.isEmpty { stack.removeLast() }
        }

        static func seconds(_ s: String) -> Double {
            if s.hasSuffix("s") {
                let body = String(s.dropLast())
                let parts = body.split(separator: "/")
                if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
                if let v = Double(body) { return v }
            }
            return 0
        }
    }
}
