import Foundation

/// Imports a Premiere (xmeml) edit into a project: media, cuts and timing.
@MainActor
enum PremiereXMLImporter {
    static func importProject(from url: URL, model: EditorModel) async -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        guard let parsed = parser.result else { return false }

        var assetMap: [String: MediaAsset] = [:]
        for (aid, info) in parsed.assets {
            let fileURL = URL(string: info.src) ?? URL(fileURLWithPath: info.src)
            if let asset = await model.media.importFile(fileURL) {
                assetMap[aid] = asset
            } else {
                let asset = MediaAsset(id: UUID(), path: fileURL.path, name: info.name, kind: info.hasVideo ? .video : .audio,
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

        for clip in parsed.clips {
            guard let asset = assetMap[clip.assetID] else { continue }
            let dur = clip.duration > 0 ? clip.duration : max(1.0 / project.fps, asset.duration - clip.start)
            guard dur >= 1.0 / project.fps else { continue }
            if clip.isVideo {
                var v = Clip(trackID: vTrack, kind: .video, assetID: asset.id, start: clip.start, duration: dur)
                v.sourceStart = clip.inPoint
                project.clips.append(v)
                if asset.hasAudio {
                    let link = UUID()
                    v.linkID = link
                    // update the appended clip's linkID
                    if let idx = project.clips.lastIndex(where: { $0.id == v.id }) { project.clips[idx].linkID = link }
                    var au = Clip(trackID: aTrack, kind: .audio, assetID: asset.id, start: clip.start, duration: dur)
                    au.linkID = link
                    au.sourceStart = clip.inPoint
                    project.clips.append(au)
                }
            } else {
                var a = Clip(trackID: aTrack, kind: .audio, assetID: asset.id, start: clip.start, duration: dur)
                a.sourceStart = clip.inPoint
                project.clips.append(a)
            }
        }

        model.load(project, url: nil)
        model.markDirty()
        return true
    }

    // MARK: Parsing

    private struct AssetInfo { var name: String; var src: String; var duration: Double; var hasVideo: Bool; var hasAudio: Bool }
    private struct ClipInfo { var assetID: String; var start: Double; var duration: Double; var inPoint: Double; var isVideo: Bool }

    private final class Parser: NSObject, XMLParserDelegate {
        var result: Parsed?
        struct Parsed {
            var width = 1920, height = 1080, fps = 30.0
            var assets: [String: AssetInfo] = [:]
            var clips: [ClipInfo] = []
        }
        private var parsed = Parsed()
        private var stack: [String] = []
        private var text = ""
        private var timebase = 30.0
        private var inVideoTrack = false
        private var inAudioTrack = false
        // current clipitem fields
        private var curName = ""
        private var curDuration = 0.0
        private var curStart = 0.0
        private var curEnd = 0.0
        private var curIn = 0.0
        private var curOut = 0.0
        private var curAssetID = ""
        private var curHasVideo = true
        private var curHasAudio = false
        private var inClipItem = false
        private var inFile = false
        private var fileSrc = ""
        private var fileName = ""
        private var fileDuration = 0.0
        private var inRate = false
        private var inTimebase = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            stack.append(elementName)
            text = ""
            if elementName == "sequence" {
                if let w = attributes["width"], let wi = Int(w) { parsed.width = wi }
                if let h = attributes["height"], let hi = Int(h) { parsed.height = hi }
            }
            if elementName == "rate" { inRate = true }
            if elementName == "timebase" { inTimebase = true }
            if elementName == "video" { inVideoTrack = true; inAudioTrack = false }
            if elementName == "audio" { inAudioTrack = true; inVideoTrack = false }
            if elementName == "track" {
                // track itself; nothing
            }
            if elementName == "clipitem" {
                inClipItem = true
                curName = attributes["name"] ?? ""
                curDuration = 0; curStart = 0; curEnd = 0; curIn = 0; curOut = 0
                curAssetID = ""; curHasVideo = inVideoTrack; curHasAudio = inAudioTrack
                fileSrc = ""; fileName = ""; fileDuration = 0
            }
            if elementName == "file" {
                inFile = true
                if let id = attributes["id"] { curAssetID = id }
                if let name = attributes["name"] { fileName = name }
            }
            if elementName == "pathurl", inFile {
                // text follows
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
            if inTimebase && inRate {
                let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if v > 0 { timebase = v }
            }
            if inFile && stack.last == "pathurl" {
                fileSrc += string
            }
            if inClipItem && stack.last == "duration" {
                // handled in didEndElement
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            switch elementName {
            case "timebase":
                if inRate, v > 0 { timebase = v }
            case "duration":
                if inClipItem && !inFile { curDuration = v } // frames
                if inFile { fileDuration = v }
            case "start":
                if inClipItem && !inFile { curStart = v }
            case "end":
                if inClipItem && !inFile { curEnd = v }
            case "in":
                if inClipItem && !inFile { curIn = v }
            case "out":
                if inClipItem && !inFile { curOut = v }
            case "pathurl":
                if inFile { fileSrc = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            case "file":
                inFile = false
                let aid = curAssetID.isEmpty ? UUID().uuidString : curAssetID
                if parsed.assets[aid] == nil {
                    parsed.assets[aid] = AssetInfo(name: fileName.isEmpty ? "Media" : fileName,
                                                   src: fileSrc, duration: fileDuration / timebase,
                                                   hasVideo: curHasVideo, hasAudio: curHasAudio)
                }
                curAssetID = aid
            case "clipitem":
                inClipItem = false
                // convert frames to seconds
                let startSec = curStart / timebase
                let durSec = (curOut > curIn ? (curOut - curIn) : curDuration) / timebase
                let inSec = curIn / timebase
                if !curAssetID.isEmpty && durSec > 0 {
                    parsed.clips.append(ClipInfo(assetID: curAssetID, start: startSec, duration: durSec, inPoint: inSec, isVideo: curHasVideo))
                }
            case "rate":
                inRate = false
            case "video":
                inVideoTrack = false
            case "audio":
                inAudioTrack = false
            default: break
            }
            text = ""
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}
