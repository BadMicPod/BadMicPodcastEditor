import Foundation
import SwiftUI

/// The numbers behind a learned style, kept apart from the words so Local and later features can use them.
struct StyleFacts: Codable, Hashable {
    var cutsPerMinute: Double?
    var averageShot: Double?
    var width: Int?
    var height: Int?
    var fps: Double?
    var multicam: Bool?
    var captions: Bool?
    var transitions: Int?
    var titles: Int?
    var hasMusic: Bool?
    var duckedMusic: Bool?
    var audioGain: Double?
    var captionSize: Double?
    var captionPosition: Double?
    var tracksUsed: Int?
    var averageGap: Double?
}

/// A client's editing style: what they like, learned from a finished episode or an edit XML.
struct ClientStyle: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Words the editor wrote about the client's style.
    var instructions: String = ""
    /// A profile learned from a finished edit or an XML.
    var profile: String = ""
    /// What the profile was learned from ("Episode 12", "client.xml").
    var trainedFrom: String = ""
    /// The same profile as numbers, for Local and anything else that can't read prose.
    var facts: StyleFacts?
    /// Optional delivery target the client expects, e.g. "-14 LUFS for YouTube".
    var loudnessTarget: String = ""
    var updated = Date()

    init(name: String, instructions: String = "") {
        self.name = name
        self.instructions = instructions
    }

    /// Every field optional: a store saved by an older or newer build still opens, rather than
    /// taking the clients down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Client"
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        trainedFrom = try c.decodeIfPresent(String.self, forKey: .trainedFrom) ?? ""
        facts = try c.decodeIfPresent(StyleFacts.self, forKey: .facts)
        loudnessTarget = try c.decodeIfPresent(String.self, forKey: .loudnessTarget) ?? ""
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, profile, trainedFrom, facts, loudnessTarget, updated
    }

    var summary: String {
        var parts = [instructions, profile].filter { !$0.isEmpty }
        if !loudnessTarget.isEmpty { parts.append("Delivery: \(loudnessTarget).") }
        return parts.joined(separator: "\n\n")
    }
}

/// The clients and their styles, kept for the whole app (not one project), next to the app's other data.
@MainActor
final class StyleStore: ObservableObject {
    static let shared = StyleStore()

    @Published private(set) var styles: [ClientStyle] = []
    @Published var activeID: UUID? {
        didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: "activeClientStyle") }
    }
    /// A saved file that couldn't be read and was kept aside, so nothing new overwrites it.
    @Published private(set) var loadProblem: String?
    private var problemShown = false

    var active: ClientStyle? { styles.first { $0.id == activeID } }

    /// The load problem, the first time it's asked for in this run (to show it once, not every popover).
    func unshownProblem() -> String? {
        guard let loadProblem, !problemShown else { return nil }
        problemShown = true
        return loadProblem
    }

    private let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("BadMicPodcastEditor/Styles.json")
    }()

    private init() {
        load()
        if let s = UserDefaults.standard.string(forKey: "activeClientStyle"), let id = UUID(uuidString: s) {
            if styles.contains(where: { $0.id == id }) {
                activeID = id
            } else {
                // The client was deleted: don't leave a stale id to pick up again.
                UserDefaults.standard.removeObject(forKey: "activeClientStyle")
            }
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            styles = try JSONDecoder().decode([ClientStyle].self, from: data)
        } catch {
            // Keep whatever was there for a person to recover, rather than saving over it later.
            let backup = file.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: file, to: backup)
            loadProblem = "Client styles couldn't be read. The old file is kept beside it as Styles.json.broken."
        }
    }

    private func save() {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(styles) {
            try? data.write(to: file, options: .atomic)
        }
    }

    func add(_ style: ClientStyle) {
        styles.append(style)
        if activeID == nil { activeID = style.id }
        save()
    }

    func update(_ style: ClientStyle) {
        guard let i = styles.firstIndex(where: { $0.id == style.id }) else { return }
        var s = style
        s.updated = Date()
        styles[i] = s
        save()
    }

    func remove(_ id: UUID) {
        styles.removeAll { $0.id == id }
        // Don't quietly move to another client: their style isn't the one the editor meant to use.
        if activeID == id { activeID = nil }
        save()
    }
}

/// A learned style: the words Magic reads, and the same facts as numbers.
struct LearnedStyle {
    var profile: String
    var facts: StyleFacts
}

/// Turns an edit (a project or an XML) into a short style profile an AI can follow.
enum StyleAnalyzer {
    static func learned(for p: Project) -> LearnedStyle? {
        let visual = p.clips.filter { $0.kind != .audio }
        let duration = p.duration
        guard !visual.isEmpty, duration >= 1 else { return nil }
        let shots = visual.count
        let avg = visual.map(\.duration).reduce(0, +) / Double(shots)
        let cutsPerMin = Double(shots) / max(duration / 60, 0.01)
        let transitions = p.clips.filter { $0.transitionIn != nil }.count
        let titles = p.clips.filter { $0.kind == .text }.count
        let solids = p.clips.filter { $0.kind == .solid }.count
        let grades = p.clips.filter { $0.grade != nil }.count
        let ramps = p.clips.filter { $0.ramp != nil }.count
        let frozen = p.clips.filter { $0.isFreeze }.count
        let reversed = p.clips.filter { $0.isReversed }.count
        let audioTracks = p.audioTracks.count
        let multicam = visual.filter(\.isMulticam).count
        let markers = p.markers?.count ?? 0
        let captions = p.captions != nil
        let audioClips = p.clips.filter { $0.kind == .audio }
        let musicClips = audioClips.filter { $0.linkID == nil }
        let duckedTracks = p.audioTracks.filter { $0.duckUnder != nil }.count
        let audioFades = audioClips.filter { $0.fadeIn > 0 || $0.fadeOut > 0 }.count
        let fadeIns = visual.filter { $0.fadeIn > 0 }.count
        let fadeOuts = visual.filter { $0.fadeOut > 0 }.count
        let overlays = visual.filter { c in
            (p.videoTracks.firstIndex { $0.id == c.trackID } ?? 0) > 0
        }.count
        let texts = p.clips.filter { $0.kind == .text }
        let firstText = texts.min { $0.start < $1.start }
        let first = visual.min { $0.start < $1.start }
        let last = visual.max { $0.end < $1.end }
        let audioGains = audioClips.map(\.gainDB)
        let avgAudioGain = audioGains.isEmpty ? 0.0 : audioGains.reduce(0, +) / Double(audioGains.count)
        let tracksUsed = p.videoTracks.filter { t in p.clips.contains { $0.trackID == t.id } }.count
            + p.audioTracks.filter { t in p.clips.contains { $0.trackID == t.id } }.count
        let v1Clips = p.clips.filter { $0.trackID == p.videoTracks.first?.id }.sorted { $0.start < $1.start }
        let gaps = zip(v1Clips, v1Clips.dropFirst()).map { $1.start - $0.end }.filter { $0 > 1e-6 }
        let avgGap = gaps.isEmpty ? 0.0 : gaps.reduce(0, +) / Double(gaps.count)

        var facts = StyleFacts()
        facts.cutsPerMinute = cutsPerMin
        facts.averageShot = avg
        facts.width = p.width
        facts.height = p.height
        facts.fps = p.fps
        facts.multicam = multicam > 0
        facts.captions = captions
        facts.transitions = transitions
        facts.titles = titles
        facts.hasMusic = !musicClips.isEmpty
        facts.duckedMusic = duckedTracks > 0
        facts.audioGain = avgAudioGain
        facts.captionSize = p.captions?.style.size
        facts.captionPosition = p.captions?.style.y
        facts.tracksUsed = tracksUsed
        facts.averageGap = avgGap

        var lines: [String] = []
        lines.append("Style learned from a finished \(fmt(duration)) edit: \(shots) picture clips, average shot \(String(format: "%.1f", avg))s, about \(String(format: "%.1f", cutsPerMin)) cuts per minute.")
        var bullets: [String] = []
        bullets.append("Frame: \(p.width) by \(p.height) at \(String(format: "%g", p.fps)) fps.")
        bullets.append("Pacing: \(pacing(cutsPerMin, avg: avg)).")
        if let first, visual.count > 1 { bullets.append("Opening shot: \(fmt(first.duration)); closing shot: \(fmt(last?.duration ?? first.duration)).") }
        if transitions == 0 {
            bullets.append("Transitions: hard cuts only, no transitions.")
        } else {
            let kinds = Dictionary(grouping: p.clips.compactMap(\.transitionIn), by: \.kind)
            let mix = TransitionKind.allCases.compactMap { kind -> String? in
                let n = kinds[kind]?.count ?? 0
                return n > 0 ? "\(n) \(kind.label.lowercased())" : nil
            }
            bullets.append("Transitions: \(transitions), \(mix.joined(separator: ", ")).")
        }
        if fadeIns + fadeOuts > 0 { bullets.append("Picture fades: \(fadeIns) in, \(fadeOuts) out.") }
        if overlays > 0 { bullets.append("Overlays: \(overlays) clip\(overlays == 1 ? "" : "s") above V1.") }
        if titles > 0 {
            if let firstText {
                bullets.append("Titles: \(titles), the first at \(fmt(firstText.start)). Look: \(titleLook(firstText.text)).")
            } else {
                bullets.append("Titles: \(titles).")
            }
        }
        if solids > 0 { bullets.append("Solids: \(solids).") }
        if grades > 0 { bullets.append("Colour: \(grades) graded clip\(grades == 1 ? "" : "s").") }
        if ramps > 0 { bullets.append("Speed ramps: \(ramps).") }
        if frozen > 0 { bullets.append("Freeze frames: \(frozen).") }
        if reversed > 0 { bullets.append("Reversed clips: \(reversed).") }
        if multicam > 0 {
            bullets.append("Camera: multicam, \(multicam) angle cut\(multicam == 1 ? "" : "s") across the episode.")
        } else {
            bullets.append("Camera: one angle throughout.")
        }
        if captions { bullets.append("Captions: on.") }
        if markers > 0 { bullets.append("Markers: \(markers).") }
        var audio = "Audio: \(audioTracks) audio track\(audioTracks == 1 ? "" : "s")"
        if !musicClips.isEmpty {
            let gain = musicClips.map(\.gainDB).reduce(0, +) / Double(musicClips.count)
            audio += ", \(musicClips.count) standalone music/sound clip\(musicClips.count == 1 ? "" : "s") at about \(String(format: "%.0f", gain)) dB gain"
        }
        audio += "."
        bullets.append(audio)
        if audioFades > 0 { bullets.append("Sound fades: on \(audioFades) audio clip\(audioFades == 1 ? "" : "s").") }
        if duckedTracks > 0 { bullets.append("Ducking: \(duckedTracks) track\(duckedTracks == 1 ? "" : "s") turn down under the voice.") }
        if !audioClips.isEmpty { bullets.append("Audio level: about \(String(format: "%.0f", avgAudioGain)) dB gain across \(audioClips.count) clip\(audioClips.count == 1 ? "" : "s").") }
        if tracksUsed > 0 { bullets.append("Tracks used: \(tracksUsed).") }
        if avgGap > 0.05 { bullets.append("Tightness: average gap between shots \(String(format: "%.2f", avgGap))s.") }
        if avgGap > 0 && avgGap <= 0.05 { bullets.append("Silence: tight cuts, little dead air between shots.") }
        if let c = p.captions {
            bullets.append("Captions: size \(Int(c.style.size)), at \(Int((c.style.y * 100).rounded()))% down\(c.style.highlight ? ", word highlight on" : "").")
        }
        lines.append(contentsOf: bullets.map { "- \($0)" })
        lines.append("Follow this recipe when cutting a new episode: match the shot lengths, pacing, use of transitions, titles, colour and sound treatment.")
        return LearnedStyle(profile: lines.joined(separator: "\n"), facts: facts)
    }

    private static func titleLook(_ text: TextStyle) -> String {
        let font = text.fontName.isEmpty ? "the system font" : text.fontName
        return "\(font) \(Int(text.size)) pt \(text.bold ? "bold" : "regular"), \(Int((text.x * 100).rounded()))% across and \(Int((text.y * 100).rounded()))% down"
    }

    private static func pacing(_ cutsPerMin: Double, avg: Double) -> String {
        if cutsPerMin >= 20 { return "very fast, \(String(format: "%.1f", avg))s shots" }
        if cutsPerMin >= 10 { return "quick, \(String(format: "%.1f", avg))s shots" }
        if cutsPerMin >= 4 { return "measured, \(String(format: "%.1f", avg))s shots" }
        return "slow and let shots breathe, \(String(format: "%.1f", avg))s shots"
    }

    private static func fmt(_ t: Double) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    /// Pulls the basic shape out of an FCPXML or Premiere XML: clip count, lengths, transitions.
    static func learned(fromXML text: String) -> LearnedStyle? {
        let parser = XMLShape()
        guard let data = text.data(using: .utf8) else { return nil }
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        // Nothing with a length: a stills timeline, or an XML shape this doesn't know.
        guard parser.clips > 0, parser.seconds >= 1 else { return nil }
        let total = parser.seconds
        let avg = total / Double(parser.clips)
        let cutsPerMin = Double(parser.clips) / max(total / 60, 0.01)
        var facts = StyleFacts()
        facts.cutsPerMinute = cutsPerMin
        facts.averageShot = avg
        facts.transitions = parser.transitions
        let profile = """
        Style learned from an edit XML: \(parser.clips) picture clips over \(fmt(total)), average shot \(String(format: "%.1f", avg))s, about \(String(format: "%.1f", cutsPerMin)) cuts per minute, \(parser.transitions) transition\(parser.transitions == 1 ? "" : "s").
        Use the same shot lengths, order logic and transition habits when cutting a new episode.
        """
        return LearnedStyle(profile: profile, facts: facts)
    }

    // MARK: Local

    /// What Local can take from a client: its pace and frame shape.
    static func applyLocalDefaults(_ style: ClientStyle, to recipe: inout LocalRecipe) {
        guard let facts = style.facts else { return }
        if recipe.pace == .unchanged, let cuts = facts.cutsPerMinute {
            if cuts >= 10 { recipe.pace = .fast } else if cuts <= 4 { recipe.pace = .calm }
        }
        if recipe.frame == .unchanged, let w = facts.width, let h = facts.height {
            if h > w { recipe.frame = .vertical } else if h == w { recipe.frame = .square }
        }
    }

    private final class XMLShape: NSObject, XMLParserDelegate {
        var clips = 0
        var transitions = 0
        var seconds = 0.0

        /// Elements open right now, outermost first.
        private var stack: [String] = []
        /// The length and place of each open clip, by its depth in the stack.
        private var clipStates: [Int: ClipState] = [:]
        private var text = ""
        /// Premiere counts in frames: the sequence's rate.
        private var timebase = 30.0
        private var haveSequenceTimebase = false
        private var isPremiere = false

        private struct ClipState {
            var length = 0.0
            var start = 0.0
            var end = 0.0
            var hasAttributeDuration = false
            /// A container clip (a compound or multicam clip) whose own clips stand for it.
            var hasNested = false
            /// Pictures inside a container, kept until the container closes.
            var childSeconds = 0.0
            var childClips = 0
            /// Premiere audio clips aren't picture.
            var counts = true
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            let depth = stack.count
            stack.append(elementName)
            text = ""
            if elementName == "xmeml" { isPremiere = true }
            if elementName == "transition" || elementName == "transitionitem" {
                if !(isPremiere && inAudio()) { transitions += 1 }
            }
            if isClip(elementName) {
                if let outer = stack.dropLast().lastIndex(where: isClip) {
                    clipStates[outer]?.hasNested = true
                }
                var state = ClipState()
                if let duration = attributes["duration"] {
                    state.length = Self.seconds(duration, fps: timebase)
                    state.hasAttributeDuration = true
                }
                if isPremiere, inAudio() { state.counts = false }
                clipStates[depth] = state
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            let value = Self.seconds(text.trimmingCharacters(in: .whitespacesAndNewlines), fps: timebase)
            switch elementName {
            case "timebase":
                // The sequence's rate, not a file's: a 30 fps stock clip in a 25 fps cut shouldn't
                // change how later frame counts are read.
                let rate = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if rate > 0, stack.contains("sequence"), !stack.contains("file"), !haveSequenceTimebase {
                    timebase = rate
                    haveSequenceTimebase = true
                }
            case "duration" where isClip(parent):
                if clipStates[stack.count - 2]?.hasAttributeDuration == false, value > 0 {
                    clipStates[stack.count - 2]?.length = value
                }
            case "start" where isClip(parent):
                if value > 0 { clipStates[stack.count - 2]?.start = value }
            case "end" where isClip(parent):
                if value > 0 { clipStates[stack.count - 2]?.end = value }
            default: break
            }
            if isClip(elementName) {
                settle(depth: stack.count - 1)
            }
            text = ""
            if !stack.isEmpty { stack.removeLast() }
        }

        /// Counts a finished clip. A container's pictures settle against its own trims, then go up to
        /// the container around it (if any) rather than straight onto the timeline's totals.
        private func settle(depth: Int) {
            guard let state = clipStates.removeValue(forKey: depth) else { return }
            let own = state.end > state.start ? state.end - state.start : state.length
            let total: Double
            let count: Int
            if state.hasNested {
                // A compound or multicam clip trimmed shorter than what's inside it still ran for its
                // own length; its cuts are its children's cuts.
                total = own > 0 ? min(state.childSeconds, own) : state.childSeconds
                count = max(state.childClips, 1)
            } else {
                total = own
                count = 1
            }
            guard state.counts, total > 0 else { return }
            if let outer = stack.dropLast().lastIndex(where: isClip) {
                clipStates[outer]?.childSeconds += total
                clipStates[outer]?.childClips += count
            } else {
                clips += count
                seconds += total
            }
        }

        /// The nearest video or audio track around the open element (Premiere only).
        private func inAudio() -> Bool {
            for name in stack.reversed() {
                if name == "audio" { return true }
                if name == "video" { return false }
            }
            return false
        }

        private func isClip(_ name: String) -> Bool {
            ["clip", "asset-clip", "title", "still", "image", "clipitem",
             "mc-clip", "sync-clip", "ref-clip"].contains(name)
        }

        /// FCPXML durations look like "3600/30000s" or "00:00:01:12"; Premiere uses frames or ticks.
        static func seconds(_ s: String, fps: Double = 30) -> Double {
            if s.hasSuffix("s") {
                let body = String(s.dropLast())
                let parts = body.split(separator: "/")
                if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
                if let v = Double(body) { return v }
            }
            let parts = s.split(separator: ":")
            if parts.count == 4, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]), let f = Double(parts[3]) {
                return h * 3600 + m * 60 + sec + f / max(fps, 1)
            }
            // Premiere's ticks: 254,016,000,000 to a second. Small numbers are frames.
            if let v = Double(s), v > 0 {
                if v > 1_000_000 { return v / 254_016_000_000 }
                return v / max(fps, 1)
            }
            return 0
        }
    }
}
