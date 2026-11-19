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

/// `@playhead`, `@selected`, `@in-out` and `@` + a library file's name, typed in the Magic box to say
/// exactly what a request is about.
enum MagicMention: Hashable {
    case playhead, selected, range
    case media(UUID)

    static let words: [(word: String, mention: MagicMention)] = [("playhead", .playhead), ("selected", .selected), ("in-out", .range)]

    /// Every mention in the text, in order, with where it is (UTF-16, for the text view). A file's name
    /// counts with or without its extension; the longest name that fits wins.
    static func find(in text: String, media: [MediaAsset]) -> [(range: NSRange, mention: MagicMention)] {
        let s = text as NSString
        guard s.range(of: "@").location != NSNotFound else { return [] }
        var names: [(String, MagicMention)] = words.map { ($0.word, $0.mention) }
        for a in media {
            names.append((a.name, .media(a.id)))
            let bare = (a.name as NSString).deletingPathExtension
            if !bare.isEmpty, bare != a.name { names.append((bare, .media(a.id))) }
        }
        names.sort { $0.0.count > $1.0.count }
        func isWordChar(_ c: unichar) -> Bool {
            guard let u = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(u) || c == 0x5F // _
        }
        var out: [(NSRange, MagicMention)] = []
        var i = 0
        while i < s.length {
            let at = s.range(of: "@", range: NSRange(location: i, length: s.length - i))
            guard at.location != NSNotFound else { break }
            i = at.location + 1
            // Not the middle of an address ("me@example.com").
            if at.location > 0, isWordChar(s.character(at: at.location - 1)) { continue }
            // "@media:club" is "@club", written the way the list browses to it.
            var from = i
            let prefix = "media:"
            if from + prefix.count <= s.length,
               s.substring(with: NSRange(location: from, length: prefix.count)).caseInsensitiveCompare(prefix) == .orderedSame {
                from += prefix.count
            }
            for (name, mention) in names {
                if from != i { guard case .media = mention else { continue } }
                let len = (name as NSString).length
                guard from + len <= s.length,
                      s.substring(with: NSRange(location: from, length: len)).caseInsensitiveCompare(name) == .orderedSame else { continue }
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
    static func plain(_ text: String, media: [MediaAsset]) -> String {
        var s = text as NSString
        for (r, m) in find(in: text, media: media).reversed() {
            let words: String = switch m {
            case .playhead: "the playhead"
            case .selected: "the selected clips"
            case .range: "the marked range"
            case .media(let id): media.first { $0.id == id }?.name ?? s.substring(with: r)
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
