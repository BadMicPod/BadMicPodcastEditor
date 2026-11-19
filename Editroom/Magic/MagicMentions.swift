import Foundation

/// What someone is pointing at when they ask Magic for something: where the playhead is, the clips
/// they have selected and the in/out range. Read when they press Make it, before Magic locks the
/// window and clears the selection.
struct MagicPointers {
    var playhead: Double
    /// Selected clips, in timeline order.
    var selected: [UUID]
    var range: (start: Double, end: Double)?

    @MainActor static func now(_ model: EditorModel) -> MagicPointers {
        let p = model.project
        let selected = p.clips.filter { model.selection.contains($0.id) }
            .sorted { ($0.start, p.trackOrder($0.trackID)) < ($1.start, p.trackOrder($1.trackID)) }.map(\.id)
        return MagicPointers(playhead: model.playhead, selected: selected, range: p.playRange)
    }
}

/// `@playhead`, `@selected`, `@in-out`, `@` + a library file's name, and `@clip:` + one clip on the
/// timeline, typed in the Magic box to say exactly what a request is about.
enum MagicMention: Hashable {
    case playhead, selected, range
    case media(UUID)
    /// One clip on the timeline (a title, a solid, or one use of a file).
    case clip(UUID)

    static let words: [(word: String, mention: MagicMention)] = [("playhead", .playhead), ("selected", .selected), ("in-out", .range)]

    /// A clip on the timeline as `@clip:` names it: a file's name, a title's words (cut short), or
    /// "Solid"; a name used more than once gets ·2, ·3… in time order. A video's own sound isn't listed
    /// apart from it.
    struct ClipLabel {
        let id: UUID
        let name: String
        let kind: ClipKind
        let track: String
        let start: Double
    }

    static func clipLabels(_ p: Project) -> [ClipLabel] {
        let videoLinks = Set(p.clips.filter { $0.kind != .audio }.compactMap(\.linkID))
        let clips = p.clips.filter { !($0.kind == .audio && $0.linkID.map(videoLinks.contains) == true) }
            .sorted { ($0.start, p.trackOrder($0.trackID)) < ($1.start, p.trackOrder($1.trackID)) }
        func base(_ c: Clip) -> String {
            let n = p.name(of: c).trimmingCharacters(in: .whitespaces)
            guard c.kind == .text, n.count > 24 else { return n }
            return String(n.prefix(22)).trimmingCharacters(in: .whitespaces) + "…"
        }
        func track(_ c: Clip) -> String {
            if let i = p.videoTracks.firstIndex(where: { $0.id == c.trackID }) { return "V\(i + 1)" }
            return "A\((p.audioTracks.firstIndex { $0.id == c.trackID } ?? 0) + 1)"
        }
        var seen: [String: Int] = [:]
        return clips.map { c in
            let b = base(c)
            let n = (seen[b.lowercased()] ?? 0) + 1
            seen[b.lowercased()] = n
            return ClipLabel(id: c.id, name: n == 1 ? b : "\(b)·\(n)", kind: c.kind, track: track(c), start: c.start)
        }
    }

    /// Every mention in the text, in order, with where it is (UTF-16, for the text view). A file's name
    /// counts with or without its extension; the longest name that fits wins.
    static func find(in text: String, media: [MediaAsset], clips: [ClipLabel] = []) -> [(range: NSRange, mention: MagicMention)] {
        let s = text as NSString
        guard s.range(of: "@").location != NSNotFound else { return [] }
        var names: [(String, MagicMention)] = words.map { ($0.word, $0.mention) }
        for a in media {
            names.append((a.name, .media(a.id)))
            let bare = (a.name as NSString).deletingPathExtension
            if !bare.isEmpty, bare != a.name { names.append((bare, .media(a.id))) }
        }
        names.sort { $0.0.count > $1.0.count }
        let clipNames = clips.map { ($0.name, MagicMention.clip($0.id)) }.sorted { $0.0.count > $1.0.count }
        func isWordChar(_ c: unichar) -> Bool {
            guard let u = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(u) || c == 0x5F // _
        }
        func starts(_ word: String, at i: Int) -> Bool {
            let n = (word as NSString).length
            return i + n <= s.length && s.substring(with: NSRange(location: i, length: n)).caseInsensitiveCompare(word) == .orderedSame
        }
        var out: [(NSRange, MagicMention)] = []
        var i = 0
        while i < s.length {
            let at = s.range(of: "@", range: NSRange(location: i, length: s.length - i))
            guard at.location != NSNotFound else { break }
            i = at.location + 1
            // Not the middle of an address ("me@example.com").
            if at.location > 0, isWordChar(s.character(at: at.location - 1)) { continue }
            // "@media:club" is "@club", written the way the list browses to it; "@clip:" names one clip.
            var from = i
            var pool = names
            if starts("media:", at: i) {
                from += 6
                pool = names.filter { if case .media = $0.1 { return true } else { return false } }
            } else if starts("clip:", at: i) {
                from += 5
                pool = clipNames
            }
            for (name, mention) in pool {
                let len = (name as NSString).length
                guard starts(name, at: from) else { continue }
                // The whole name: "@intro" isn't "@introduction".
                if from + len < s.length, isWordChar(s.character(at: from + len)) { continue }
                out.append((NSRange(location: at.location, length: from + len - at.location), mention))
                i = from + len
                break
            }
        }
        return out
    }

    /// The request in plain words, for a reader that doesn't know about mentions (Apple's model):
    /// "@selected" reads "the selected clips", "@beach.mov" reads "beach.mov".
    static func plain(_ text: String, media: [MediaAsset], clips: [ClipLabel] = []) -> String {
        var s = text as NSString
        for (r, m) in find(in: text, media: media, clips: clips).reversed() {
            let words: String = switch m {
            case .playhead: "the playhead"
            case .selected: "the selected clips"
            case .range: "the marked range"
            case .media(let id): media.first { $0.id == id }?.name ?? s.substring(with: r)
            case .clip(let id): "the clip " + (clips.first { $0.id == id }?.name ?? "")
            }
            s = s.replacingCharacters(in: r, with: words) as NSString
        }
        return s as String
    }
}

extension Project {
    /// Where a track sits for sorting: video tracks top to bottom, then audio.
    func trackOrder(_ id: UUID) -> Int {
        if let i = videoTracks.firstIndex(where: { $0.id == id }) { return videoTracks.count - i }
        return videoTracks.count + 1 + (audioTracks.firstIndex { $0.id == id } ?? 0)
    }
}
