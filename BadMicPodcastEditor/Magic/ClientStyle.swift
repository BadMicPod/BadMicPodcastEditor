import Foundation
import SwiftUI

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
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, profile, trainedFrom, updated
    }

    var summary: String {
        [instructions, profile].filter { !$0.isEmpty }.joined(separator: "\n\n")
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

    var active: ClientStyle? { styles.first { $0.id == activeID } }

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

/// Turns an edit (a project or an XML) into a short style profile an AI can follow.
enum StyleAnalyzer {
    static func profile(for p: Project) -> String? {
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
        let musicLike = p.clips.filter { c in
            c.kind == .audio && c.linkID == nil
        }.count
        var lines: [String] = []
        lines.append("Style learned from a finished \(fmt(duration)) edit: \(shots) picture clips, average shot \(String(format: "%.1f", avg))s, about \(String(format: "%.1f", cutsPerMin)) cuts per minute.")
        var facts: [String] = []
        facts.append("Frame: \(p.width) by \(p.height) at \(String(format: "%g", p.fps)) fps.")
        facts.append("Pacing: \(pacing(cutsPerMin, avg: avg)).")
        facts.append("Transitions: \(transitions == 0 ? "hard cuts only, no transitions" : "\(transitions) transition\(transitions == 1 ? "" : "s")").")
        if titles > 0 { facts.append("Titles: \(titles) on the timeline.") }
        if solids > 0 { facts.append("Solids: \(solids).") }
        if grades > 0 { facts.append("Colour: \(grades) graded clip\(grades == 1 ? "" : "s").") }
        if ramps > 0 { facts.append("Speed ramps: \(ramps).") }
        if frozen > 0 { facts.append("Freeze frames: \(frozen).") }
        if reversed > 0 { facts.append("Reversed clips: \(reversed).") }
        if multicam > 0 {
            facts.append("Camera: multicam, \(multicam) angle cut\(multicam == 1 ? "" : "s") across the episode.")
        } else {
            facts.append("Camera: one angle throughout.")
        }
        if captions { facts.append("Captions: on.") }
        if markers > 0 { facts.append("Markers: \(markers).") }
        facts.append("Audio: \(audioTracks) audio track\(audioTracks == 1 ? "" : "s")\(musicLike > 0 ? ", \(musicLike) standalone sound/music clip\(musicLike == 1 ? "" : "s")" : "").")
        lines.append(contentsOf: facts.map { "- \($0)" })
        lines.append("Follow this recipe when cutting a new episode: match the shot lengths, pacing, use of transitions, titles, colour and sound treatment.")
        return lines.joined(separator: "\n")
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
    static func profile(fromXML text: String) -> String? {
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
        return """
        Style learned from an edit XML: \(parser.clips) picture clips over \(fmt(total)), average shot \(String(format: "%.1f", avg))s, about \(String(format: "%.1f", cutsPerMin)) cuts per minute, \(parser.transitions) transition\(parser.transitions == 1 ? "" : "s").
        Use the same shot lengths, order logic and transition habits when cutting a new episode.
        """
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
                if let state = clipStates.removeValue(forKey: stack.count - 1) {
                    // Placed length (end - start) beats the source length for a trimmed Premiere clip;
                    // a container's own clips are counted instead of it.
                    let length = state.end > state.start ? state.end - state.start : state.length
                    if state.counts, !state.hasNested, length > 0 {
                        clips += 1
                        seconds += length
                    }
                }
            }
            text = ""
            if !stack.isEmpty { stack.removeLast() }
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
