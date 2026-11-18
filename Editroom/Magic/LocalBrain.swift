import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What Local Magic should do, worked out from what the person typed. Local's own planner follows it:
/// nothing here edits anything by itself.
struct LocalRecipe: Equatable {
    enum Pace: String { case unchanged, calm, fast }
    enum Music: String { case unchanged, off, add }
    enum Frame: String { case unchanged, vertical, horizontal, square }

    /// How long the video should be, if they said.
    var seconds: Double?
    var pace: Pace = .unchanged
    /// A built-in look for every shot; "none" takes looks off; nil leaves colour alone.
    var look: String?
    var music: Music = .unchanged
    var frame: Frame = .unchanged
    /// Anything they asked for that these settings can't do.
    var cannotDo = ""

    static let plain = LocalRecipe()

    /// "20s, fast, Mono, no music, vertical", for the log and the note.
    var summary: String {
        var parts: [String] = []
        if let seconds { parts.append("\(Int(seconds))s") }
        if pace != .unchanged { parts.append(pace.rawValue) }
        if let look { parts.append(look == "none" ? "no look" : look) }
        if music == .off { parts.append("no music") } else if music == .add { parts.append("music added") }
        if frame != .unchanged { parts.append(frame.rawValue) }
        return parts.joined(separator: ", ")
    }
}

/// Apple's on-device model (Apple Intelligence), used only to turn a request into a `LocalRecipe`. Free,
/// private and offline; on Macs without it, Local works without prompts.
enum LocalBrain {
    static let looks = ["Warm film", "Golden hour", "Film print", "Teal and orange", "Pastel", "Bleach bypass", "Mono", "Cool night", "Faded"]

    /// Why prompts can't be used on this Mac, or nil if they can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to describe what you want."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready on this Mac."
            case .unavailable: return "Describing what you want needs a Mac with Apple Intelligence."
            }
        }
        #endif
        return "Describing what you want needs macOS 26 or later with Apple Intelligence."
    }

    static var available: Bool { unavailableReason == nil }

    struct Failure: Error { let message: String }

    /// The small model tends to fill in settings nobody asked for. A setting only stands if the request
    /// talks about that kind of thing; a "can't do" only if it's about something they said that the
    /// settings don't cover.
    static func checked(_ r: LocalRecipe, against request: String) -> LocalRecipe {
        let text = request.lowercased()
        func says(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        let lengthWords = ["second", "sec", "minute", "min", "long", "short", "length", "s "]
        let paceWords = ["pace", "pacing", "calm", "slow", "relax", "chill", "gentle", "fast", "quick", "punch", "snappy", "energ", "rhythm", "speed", "tempo"]
        let lookWords = ["look", "grade", "colour", "color", "film", "warm", "cool", "mono", "black and white", "b&w", "bw", "vintage", "fade",
                         "pastel", "teal", "orange", "golden", "night", "bleach", "filter", "tone", "cinematic", "moody", "natural", "lut"]
        let musicWords = ["music", "song", "soundtrack", "track", "tune", "audio", "beat"]
        let frameWords = ["vertical", "portrait", "tiktok", "tik tok", "reel", "shorts", "story", "stories", "phone", "horizontal", "landscape",
                          "widescreen", "youtube", "square", "instagram", "9:16", "16:9", "1:1"]
        var out = r
        if out.seconds != nil, !(says(lengthWords) && text.contains(where: \.isNumber)) { out.seconds = nil }
        if out.pace != .unchanged, !says(paceWords) { out.pace = .unchanged }
        if out.look != nil, !says(lookWords) { out.look = nil }
        if out.music != .unchanged, !says(musicWords) { out.music = .unchanged }
        if out.music == .off, !says(["no ", "without", "remove", "off", "mute", "silent", "drop", "take out"]) { out.music = .unchanged }
        if out.frame != .unchanged, !says(frameWords) { out.frame = .unchanged }
        // "Can't do": only parts that share a real word with the request, and aren't about what was done.
        let handled = (out.music != .unchanged ? musicWords : []) + (out.look != nil ? lookWords : [])
            + (out.frame != .unchanged ? frameWords : []) + (out.pace != .unchanged ? paceWords : []) + (out.seconds != nil ? lengthWords : [])
        let requestWords = Set(text.split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
        let parts = r.cannotDo.split(separator: ",").flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let kept = parts.filter { part in
            let p = part.lowercased()
            let shares = p.split { !$0.isLetter }.contains { w in requestWords.contains { $0.hasPrefix(String(w.prefix(5))) && w.count >= 4 } }
            let aboutHandled = handled.contains { p.contains($0) }
            return shares && !aboutHandled
        }
        out.cannotDo = kept.joined(separator: ", ")
        return out
    }

    static func recipe(for request: String) async throws -> LocalRecipe {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), available {
            let session = LanguageModelSession(instructions: """
            You turn a person's request for editing their video into settings. Set a field ONLY if their \
            words ask for it; every other field stays "unchanged" (seconds stays 0). Most requests change one \
            or two fields. The editor can only: set a length, make the pacing calm or fast, put one colour \
            look on every shot or take looks off, turn music off or add music from their library, and make \
            the frame vertical, horizontal or square. If they ask for something else (sound effects, a title \
            or text, a particular story, effects), write just that in cannotDo, in their words; otherwise \
            leave cannotDo empty. Never mention anything they didn't ask for.
            """)
            do {
                let out = try await session.respond(to: request, generating: RecipeOut.self).content
                var r = LocalRecipe()
                r.seconds = out.seconds > 0 ? Double(out.seconds) : nil
                r.pace = LocalRecipe.Pace(rawValue: out.pace) ?? .unchanged
                r.look = out.look == "unchanged" ? nil : out.look
                r.music = LocalRecipe.Music(rawValue: out.music) ?? .unchanged
                r.frame = LocalRecipe.Frame(rawValue: out.frame) ?? .unchanged
                r.cannotDo = out.cannotDo.trimmingCharacters(in: .whitespacesAndNewlines)
                return checked(r, against: request)
            } catch {
                throw Failure(message: "Apple Intelligence couldn't read that: \(error.localizedDescription)")
            }
        }
        #endif
        throw Failure(message: unavailableReason ?? "Apple Intelligence isn't available.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable(description: "Settings for editing a video, from the person's request")
struct RecipeOut {
    @Guide(description: "How long the video should be, in seconds; 0 if they didn't say", .range(0...900))
    var seconds: Int
    @Guide(description: "Pacing: calm (longer, slower shots), fast (short, punchy shots), or unchanged", .anyOf(["unchanged", "calm", "fast"]))
    var pace: String
    @Guide(description: "One colour look for every shot, none to take looks off, or unchanged",
           .anyOf(["unchanged", "none", "Warm film", "Golden hour", "Film print", "Teal and orange", "Pastel", "Bleach bypass", "Mono", "Cool night", "Faded"]))
    var look: String
    @Guide(description: "Music: off to remove it, add to put a song from their library under it, or unchanged", .anyOf(["unchanged", "off", "add"]))
    var music: String
    @Guide(description: "Frame shape: vertical (for phones, Reels, TikTok, Shorts), horizontal, square, or unchanged",
           .anyOf(["unchanged", "vertical", "horizontal", "square"]))
    var frame: String
    @Guide(description: "What they asked for that these settings can't do, in a few plain words; empty if nothing")
    var cannotDo: String
}
#endif
