import AppKit
import Foundation

struct MCPToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The tools agents get. Reading is instant; every change to the cut is played by the agent's own
/// cursor (dragging from the library, trimming edges, working the grade panel) and is one undo step.
@MainActor
enum MCPTools {
    static let instructions = """
    Editroom is a video editor. Times are in seconds. Video tracks are V1, V2, … (V1 is the bottom; \
    higher tracks cover lower ones) and audio tracks are A1, A2, …. A video with sound is placed as a \
    linked pair: moving, trimming or deleting either moves both. Placing, moving or trimming a clip \
    over another on the same track overwrites what's underneath, as on the timeline. Start with \
    get_project and list_media; analyze_media finds a clip's best moments or a song's beats; \
    look_at_media shows you a clip or photo, and get_frame shows you the cut. Each edit is shown to the person with your own cursor and can be \
    undone with history. auto_edit builds a whole cut on its own.
    """

    static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: Definitions

    private static func tool(_ name: String, _ title: String, _ description: String, _ props: [String: Any] = [:],
                             required: [String] = [], readOnly: Bool = false) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false],
        ]
    }
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }

    static var definitions: [[String: Any]] {
        [
            tool("get_project", "Get project", "The sequence (size, frame rate, length), tracks, and every clip with its id, track, times, source, grade, sound and transition.", readOnly: true),
            tool("list_media", "List media", "Everything in the library: id, name, kind (video, audio, image), length, size, frame rate.", readOnly: true),
            tool("import_media", "Import media", "Adds files to the library.", ["paths": ["type": "array", "items": ["type": "string"], "description": "Absolute file paths."]], required: ["paths"]),
            tool("download_media", "Download media", "Downloads one music or sound file you found online and adds it to the library, ready for add_clip. Give the direct link to the audio file (an .mp3, .m4a or .wav), not a web page. Only for music that's free to use; say where you found it and what its licence allows, which is noted beside the file.",
                 ["url": str("https link to the audio file itself."), "name": str("What to call it, like the track and artist."),
                  "source_page": str("The page you found it on."), "licence": str("What the licence says, for example \"Pixabay Content License: free to use, no attribution required\".")],
                 required: ["url", "source_page", "licence"]),
            tool("analyze_media", "Analyze media", "For a video or photo: its best moments, scored for focus, exposure, colour, faces and steadiness. For music: tempo, beats and where bars start. Done on this Mac; cached.",
                 ["asset_id": str("A library item's id."), "moment_length": num("Length of moments to look for, in seconds (default 2).")], required: ["asset_id"], readOnly: true),
            tool("look_at_media", "Look at media", "Shows you a library item: a photo, or frames from across a video in a grid, each marked with its time in the file. Use it to see what's in each shot before choosing.",
                 ["asset_id": str("A library item's id."), "frames": ["type": "integer", "description": "How many frames from across a video (default 6, at most 12)."],
                  "times": ["type": "array", "items": ["type": "number"], "description": "Or exactly which times in the file to show, in seconds (at most 12)."]],
                 required: ["asset_id"], readOnly: true),
            tool("get_frame", "Get frame", "A picture of the cut at a time (default: the playhead), 640 pixels on its longer side.", ["time": num("Seconds.")], readOnly: true),
            tool("add_clip", "Add clip", "Drags a library item onto the timeline. A video with sound brings its audio, linked.",
                 ["asset_id": str("A library item's id."), "start": num("Where on the timeline (default: the end of the track)."),
                  "track": str("V1, V2… for video and photos; A1, A2… for audio (default V1 or A1)."),
                  "source_start": num("Where in the file to start (default 0)."), "duration": num("How long (default: the rest of the file; 5 for a photo).")],
                 required: ["asset_id"]),
            tool("add_title", "Add title", "Adds a text title, typed in.", ["text": str("The words."), "start": num("Default 0."), "duration": num("Default 3."), "track": str("A video track (default: one that's free there, above V1).")], required: ["text"]),
            tool("move_clip", "Move clip", "Moves a clip (and anything linked to it) in time, and optionally to another track of the same kind.", ["clip_id": str("A clip's id."), "start": num("New start."), "track": str("Optional new track.")], required: ["clip_id", "start"]),
            tool("trim_clip", "Trim clip", "Moves a clip's start and/or end edge on the timeline (and its linked clip's). The source moves with the start edge.", ["clip_id": str("A clip's id."), "start": num("New start edge."), "end": num("New end edge.")], required: ["clip_id"]),
            tool("set_speed", "Set speed", "Speeds a clip (and its linked sound) up or slows it down, keeping the same part of the file: 4 plays four times as fast and a quarter as long (a timelapse), 0.5 is slow motion. Clips after it on the track move to stay butted up.",
                 ["clip_id": str("A clip's id."), "speed": num("0.05...100; 1 is normal.")], required: ["clip_id", "speed"]),
            tool("split_clip", "Split clip", "Cuts a clip (and its linked clip) in two with the blade. Returns the new right-hand pieces.", ["clip_id": str("A clip's id."), "at": num("Timeline time inside the clip.")], required: ["clip_id", "at"]),
            tool("delete_clips", "Delete clips", "Deletes clips and anything linked to them.", ["clip_ids": ["type": "array", "items": ["type": "string"]], "ripple": ["type": "boolean", "description": "Close the gap left behind (default false)."]], required: ["clip_ids"]),
            tool("set_grade", "Set grade", "Colour for video, photo and title clips. Leave out what shouldn't change.",
                 ["clip_ids": ["type": "array", "items": ["type": "string"]], "look": str("A look from list_looks, a .cube file path, or \"none\"."),
                  "look_intensity": num("0...1."), "exposure": num("Stops, -2...2."), "contrast": num("-50...50."), "saturation": num("-100...100."),
                  "temperature": num("-50...50, negative is cooler."), "tint": num("-50...50, positive is toward magenta.")], required: ["clip_ids"]),
            tool("list_looks", "List looks", "The built-in looks for set_grade.", readOnly: true),
            tool("set_audio", "Set audio", "A clip's level and fades.", ["clip_id": str("A clip's id."), "gain_db": num("Level in dB, -60...12."), "fade_in": num("Seconds."), "fade_out": num("Seconds.")], required: ["clip_id"]),
            tool("set_transition", "Set transition", "A transition into a clip from the clip that ends where it starts on the same track.", ["clip_id": str("The later clip's id."), "kind": ["type": "string", "enum": ["dissolve", "dipToBlack", "wipe", "none"]], "duration": num("Seconds (default 0.5).")], required: ["clip_id", "kind"]),
            tool("add_track", "Add track", "Adds an empty track on top of the others of its kind.", ["kind": ["type": "string", "enum": ["video", "audio"]]], required: ["kind"]),
            tool("set_sequence", "Set sequence", "The frame size and frame rate of the cut.", ["width": ["type": "integer"], "height": ["type": "integer"], "fps": num("23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 100, 119.88 or 120.")]),
            tool("playback", "Playback", "Play, pause or move the playhead.", ["action": ["type": "string", "enum": ["play", "pause", "seek"]], "time": num("For seek.")], required: ["action"]),
            tool("history", "Undo or redo", "Undoes or redoes the last change (each tool call is one change).", ["action": ["type": "string", "enum": ["undo", "redo"]]], required: ["action"]),
            tool("auto_edit", "Auto edit", "Builds a whole cut from the library on its own: best moments, cut to the beat of a song if there is one, titled, graded. Replaces what's on the timeline (one undo brings it back)."),
            tool("save_project", "Save project", "Saves the project to its file. A project that's never been saved has to be saved by the person."),
        ]
    }

    // MARK: Calls

    static func call(_ name: String, _ args: [String: Any], model: EditorModel, client: MCPServer.Client?,
                     draft: MCPDraft? = nil) async throws -> [[String: Any]] {
        let who = client?.name ?? "Agent"
        draft?.called(name)
        /// The project as it is now: the Magic draft's while there is one.
        func now() -> Project { draft?.project ?? model.project }
        func notInMagic() throws {
            if draft != nil { throw MCPToolError("\(name) isn't available while making a Magic edit.") }
        }
        func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
        func json(_ v: Any) -> [[String: Any]] {
            let d = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return text(String(data: d, encoding: .utf8) ?? "{}")
        }
        let p = now()

        switch name {
        case "get_project":
            return json(projectJSON(p, title: model.title, playhead: draft?.playhead ?? model.playhead))

        case "list_media":
            return json(p.assets.map(assetJSON))

        case "list_looks":
            return json(BuiltInLook.all.map(\.name))

        case "import_media":
            try notInMagic()
            let paths = args["paths"] as? [String] ?? []
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
            guard missing.isEmpty else { throw MCPToolError("No file at " + missing.map(\.path).joined(separator: ", ")) }
            let assets: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles(urls, offerMatch: false) { cont.resume(returning: $0) }
            }
            return json(["imported": assets.map(assetJSON), "failed": urls.count - assets.count])

        case "download_media":
            guard let link = args["url"] as? String, let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else {
                throw MCPToolError("url is needed: the https link to the audio file.")
            }
            let folder = MediaDownload.folder(for: model.fileURL)
            let file: URL
            do {
                file = try await MediaDownload.fetch(url, name: args["name"] as? String, sourcePage: args["source_page"] as? String,
                                                     licence: args["licence"] as? String, into: folder)
            } catch let e as MediaDownload.Failure {
                throw MCPToolError(e.message)
            }
            let assets: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles([file], offerMatch: false) { cont.resume(returning: $0) }
            }
            guard let asset = assets.first else { throw MCPToolError("Downloaded it, but couldn't add it to the library.") }
            draft?.addAsset(asset)
            var out = assetJSON(asset)
            out["saved_to"] = file.path
            return json(["added": out, "note": "In the library now; add it with add_clip."])

        case "analyze_media":
            let asset = try assetArg(args, p)
            if asset.kind == .audio {
                guard let m = await MediaAnalyzer.music(asset.url) else { throw MCPToolError("Couldn't read the sound in \(asset.name).") }
                let bars = m.beats.indices.filter(m.isBarStart).map { round3(m.beats[$0]) }
                return json(["bpm": round3(m.bpm), "beat_length": round3(m.period), "beat_count": m.beats.count,
                             "first_beat": round3(m.beats.first ?? 0), "bar_starts": Array(bars.prefix(80))])
            }
            guard let a = await MediaAnalyzer.clip(asset.url, kind: asset.kind) else { throw MCPToolError("Couldn't look at \(asset.name).") }
            let length = (args["moment_length"] as? Double) ?? 2
            let score = AutoPlanner.scorer(a.samples)
            let moments = AutoPlanner.moments(a, limit: asset.duration, length: length, score: score)
            let mean = a.samples.map(\.luma).reduce(0, +) / Double(max(1, a.samples.count))
            var out: [String: Any] = [
                "duration": round3(min(a.duration, asset.duration)),
                "best_moments": moments.map { ["start": round3($0.start), "end": round3($0.end), "score": round3($0.score), "faces": $0.faces] },
                "average_brightness": round3(mean),
                "has_faces": a.samples.contains { $0.faces > 0 },
            ]
            if let created = a.created { out["filmed"] = ISO8601DateFormatter().string(from: created) }
            if a.samples.contains(where: { $0.utility == true }) { out["looks_like_a_screenshot_or_document"] = true }
            return json(out)

        case "look_at_media":
            let asset = try assetArg(args, p)
            guard asset.kind != .audio else { throw MCPToolError("\(asset.name) is sound only; analyze_media finds its beats.") }
            let frames = (args["frames"] as? Int) ?? 6
            let times = (args["times"] as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
            guard let sheet = await ContactSheet.make(asset, frames: frames, around: times) else { throw MCPToolError("Couldn't look at \(asset.name).") }
            let note = asset.kind == .image ? "\(asset.name), a photo." :
                "\(asset.name), \(round3(asset.duration))s long. Frames at " + sheet.times.map { String(format: "%.1fs", $0) }.joined(separator: ", ") + ", left to right, top to bottom."
            return [["type": "image", "data": sheet.jpeg.base64EncodedString(), "mimeType": "image/jpeg"], ["type": "text", "text": note]]

        case "get_frame":
            guard !p.clips.isEmpty else { throw MCPToolError("The timeline is empty.") }
            let t = (args["time"] as? Double) ?? draft?.playhead ?? model.playhead
            guard let img = await model.snapshot(of: p, at: t), let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw MCPToolError("Couldn't render a frame at \(t)s.")
            }
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                    ["type": "text", "text": "Frame at \(round3(t))s."]]

        case "add_clip":
            let asset = try assetArg(args, p)
            let audioOnly = asset.kind == .audio
            let track = try trackArg(args["track"] as? String ?? (audioOnly ? "A1" : "V1"), p, kind: audioOnly ? .audio : .video)
            let start = max(0, (args["start"] as? Double) ?? (p.clips.filter { $0.trackID == track }.map(\.end).max() ?? 0))
            let source = max(0, (args["source_start"] as? Double) ?? 0)
            guard asset.kind == .image || source < asset.duration - 0.05 else { throw MCPToolError("source_start is past the end of \(asset.name) (\(round3(asset.duration))s).") }
            let rest = asset.kind == .image ? 5 : asset.duration - source
            let length = max(1 / p.fps, min((args["duration"] as? Double) ?? rest, asset.kind == .image ? 3600 : rest))
            let audioTrack = audioOnly ? track : (p.freeTrack(.audio, start: start, duration: length) ?? p.audioTracks.first?.id ?? TrackToken.newAudio)
            var clips = model.makeClips(.asset(asset.id), at: p.snapFrame(start), videoTrack: audioOnly ? (p.videoTracks.first?.id ?? track) : track,
                                        audioTrack: audioTrack)
            for i in clips.indices {
                clips[i].sourceStart = asset.kind == .image ? 0 : source
                clips[i].duration = p.snapFrame(length)
            }
            guard !clips.isEmpty else { throw MCPToolError("Couldn't make a clip from \(asset.name).") }
            try await perform([.place(clips, asset: asset.id)], model, who, draft)
            return json(["added": clips.map { ["id": $0.id.uuidString, "track": trackName($0.trackID, now()), "start": round3($0.start), "end": round3($0.end)] }])

        case "add_title":
            let words = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { throw MCPToolError("The title needs some text.") }
            let start = max(0, (args["start"] as? Double) ?? 0)
            let length = max(0.2, (args["duration"] as? Double) ?? 3)
            let track: UUID
            var edits: [MagicEdit] = []
            if let name = args["track"] as? String {
                track = try trackArg(name, p, kind: .video)
            } else {
                // Above the picture: the first video track (not V1) that's free there.
                let free = p.videoTracks.dropFirst().first { t in !p.clips.contains { $0.trackID == t.id && $0.start < start + length && $0.end > start } }
                if let t = free?.id {
                    track = t
                } else if draft != nil {
                    // None free: a new one on top, in the same step as the title.
                    track = UUID()
                    edits.append(addTrackEdit(.video, id: track))
                } else {
                    model.addTrack(.video)
                    track = model.project.videoTracks.last!.id
                }
            }
            var clip = Clip(trackID: track, kind: .text, start: p.snapFrame(start), duration: p.snapFrame(length))
            clip.text.string = ""
            edits += [.place([clip], asset: nil), .type(clip.id, words)]
            try await perform(edits, model, who, draft)
            return json(["added": ["id": clip.id.uuidString, "track": trackName(track, now()), "start": round3(clip.start), "end": round3(clip.end)]])

        case "move_clip":
            let c = try clipArg(args, p)
            let start = max(0, try numArg(args, "start"))
            var tracks: [UUID: UUID] = [:]
            if let name = args["track"] as? String {
                tracks[c.id] = try trackArg(name, p, kind: c.kind.trackKind)
            }
            let ids = Array(p.unlocked(p.linked([c.id])))
            try await perform([.move(ids, from: c.start, to: p.snapFrame(start), tracks: tracks)], model, who, draft)
            return json(clipsJSON(ids, now()))

        case "trim_clip":
            let c = try clipArg(args, p)
            let ids = Array(p.unlocked(p.linked([c.id])))
            var edits: [MagicEdit] = []
            var newStart = c.start, newEnd = c.end
            if let s = args["start"] as? Double {
                // Not before the start of the file.
                let earliest = c.playsSource ? c.start - c.sourceStart / max(0.01, c.speed) : 0
                newStart = p.snapFrame(max(max(0, earliest), s))
            }
            if let e = args["end"] as? Double {
                var latest = Double.infinity
                if c.playsSource, let limit = p.sourceLimit(c) { latest = c.start + (limit - c.sourceStart) / max(0.01, c.speed) }
                newEnd = p.snapFrame(min(latest, e))
            }
            guard newEnd - newStart >= 1 / p.fps else { throw MCPToolError("That would leave the clip with no length.") }
            if newStart != c.start { edits.append(.trimHead(ids, from: c.start, to: newStart)) }
            if newEnd != c.end { edits.append(.trimTail(ids, from: c.end, to: newEnd)) }
            guard !edits.isEmpty else { return json(clipsJSON(ids, p)) }
            try await perform(edits, model, who, draft)
            return json(clipsJSON(ids, now()))

        case "set_speed":
            let c = try clipArg(args, p)
            guard c.playsSource else { throw MCPToolError("Only video and sound clips have a speed.") }
            let speed = try numArg(args, "speed").clamped(to: 0.05...100)
            let ids = p.unlocked(p.linked([c.id]))
            let label = speed >= 1 ? String(format: "Speed ×%g", speed) : String(format: "Slow ×%g", speed)
            try await perform([.change(c.id, label) { proj in proj.setSpeed(ids: ids, speed: speed) }], model, who, draft)
            return json(clipsJSON(Array(ids), now()))

        case "split_clip":
            let c = try clipArg(args, p)
            let at = p.snapFrame(try numArg(args, "at"))
            guard at > c.start + 0.5 / p.fps, at < c.end - 0.5 / p.fps else { throw MCPToolError("\(round3(at))s isn't inside the clip (\(round3(c.start))–\(round3(c.end))).") }
            let ids = Array(p.unlocked(p.linked([c.id])))
            var pieces: [UUID: UUID] = [:]
            for id in ids { pieces[id] = UUID() }
            try await perform([.blade(ids, at: at, pieces: pieces, link: UUID())], model, who, draft)
            return json(["left": clipsJSON(ids, now()), "right": clipsJSON(ids.compactMap { pieces[$0] }, now())])

        case "delete_clips":
            let raw = args["clip_ids"] as? [String] ?? []
            let ids = try raw.map { s -> UUID in
                guard let id = UUID(uuidString: s), p.clip(id) != nil else { throw MCPToolError("No clip with id \(s).") }
                return id
            }
            let all = Array(p.unlocked(p.linked(Set(ids))))
            guard !all.isEmpty else { throw MCPToolError("Nothing to delete (locked tracks?).") }
            try await perform([.remove(all, ripple: args["ripple"] as? Bool ?? false)], model, who, draft)
            return text("Deleted \(all.count) clip\(all.count == 1 ? "" : "s").")

        case "set_grade":
            let raw = args["clip_ids"] as? [String] ?? (args["clip_id"] as? String).map { [$0] } ?? []
            var edits: [MagicEdit] = []
            for s in raw {
                guard let id = UUID(uuidString: s), let c = p.clip(id) else { throw MCPToolError("No clip with id \(s).") }
                guard c.kind != .audio else { throw MCPToolError("\(p.name(of: c)) is sound; it has no colour.") }
                if let look = args["look"] as? String {
                    if look.lowercased() == "none" {
                        edits.append(.change(id, "No look") { proj in
                            if let i = proj.index(of: id) { var g = proj.clips[i].grade ?? ColorGrade(); g.look = nil; proj.clips[i].grade = g.isNeutral ? nil : g }
                        })
                    } else {
                        let path = (look as NSString).expandingTildeInPath
                        guard BuiltInLook.named(look) != nil || (path.hasSuffix(".cube") && GradeBaker.cubeFile(path) != nil) else {
                            throw MCPToolError("No look called \(look). list_looks has the built-in ones.")
                        }
                        edits.append(.look(id, name: BuiltInLook.named(look) != nil ? look : path))
                    }
                }
                for key in MagicGradeKey.allCases {
                    let field = key == .exposure ? "exposure" : key == .contrast ? "contrast" : "saturation"
                    if let v = args[field] as? Double { edits.append(.grade(id, key, to: v.clamped(to: key.range))) }
                }
                let intensity = args["look_intensity"] as? Double, temp = args["temperature"] as? Double, tint = args["tint"] as? Double
                if intensity != nil || temp != nil || tint != nil {
                    edits.append(.change(id, "Colour") { proj in
                        guard let i = proj.index(of: id) else { return }
                        var g = proj.clips[i].grade ?? ColorGrade()
                        if let intensity { g.lookIntensity = intensity.clamped(to: 0...1) }
                        if let temp { g.temperature = temp.clamped(to: -50...50) }
                        if let tint { g.tint = tint.clamped(to: -50...50) }
                        proj.clips[i].grade = g
                    })
                }
            }
            guard !edits.isEmpty else { throw MCPToolError("Nothing to change: give clip_ids and at least one setting.") }
            try await perform(edits, model, who, draft)
            return json(clipsJSON(raw.compactMap(UUID.init(uuidString:)), now()))

        case "set_audio":
            let c = try clipArg(args, p)
            var edits: [MagicEdit] = []
            if let g = args["gain_db"] as? Double { edits.append(.gain(c.id, from: c.gainDB, to: g.clamped(to: -60...12))) }
            if let f = args["fade_in"] as? Double { edits.append(.fadeIn(c.id, to: max(0, min(f, c.duration)))) }
            if let f = args["fade_out"] as? Double { edits.append(.fadeOut(c.id, to: max(0, min(f, c.duration)))) }
            guard !edits.isEmpty else { throw MCPToolError("Give gain_db, fade_in or fade_out.") }
            try await perform(edits, model, who, draft)
            return json(clipsJSON([c.id], now()))

        case "set_transition":
            let c = try clipArg(args, p)
            let kindName = args["kind"] as? String ?? "dissolve"
            if kindName == "none" {
                try await perform([.change(c.id, "No transition") { proj in if let i = proj.index(of: c.id) { proj.clips[i].transitionIn = nil } }], model, who, draft)
            } else {
                guard let kind = TransitionKind(rawValue: kindName) else { throw MCPToolError("kind is dissolve, dipToBlack, wipe or none.") }
                guard p.clips.contains(where: { $0.trackID == c.trackID && $0.id != c.id && abs($0.end - c.start) < 1e-3 }) else {
                    throw MCPToolError("Nothing ends where this clip starts on its track, so there's nothing to transition from.")
                }
                let t = Transition(kind: kind, duration: max(0.04, (args["duration"] as? Double) ?? 0.5))
                try await perform([.transition(c.id, t)], model, who, draft)
            }
            return json(clipsJSON([c.id], now()))

        case "add_track":
            let kind: TrackKind = (args["kind"] as? String) == "audio" ? .audio : .video
            if let draft { draft.apply([addTrackEdit(kind, id: UUID())]) } else { model.addTrack(kind) }
            let tracks = now().tracks(kind)
            return text("Added \(kind == .video ? "V" : "A")\(tracks.count).")

        case "set_sequence":
            var size: (Int, Int)?
            if let w = args["width"] as? Int, let h = args["height"] as? Int {
                guard w >= 16, h >= 16, w <= 8192, h <= 8192 else { throw MCPToolError("Width and height are 16…8192.") }
                size = (w, h)
            }
            let fps = (args["fps"] as? Double).map(EditorModel.standardFPS)
            if let draft {
                draft.apply([.change(nil, "Sequence") { proj in
                    if let size { proj.width = size.0; proj.height = size.1 }
                    if let fps { proj.fps = fps }
                    proj.settingsLocked = true
                }])
            } else {
                if let size { model.setSequence(width: size.0, height: size.1) }
                if let fps { model.setFPS(fps) }
            }
            let q = now()
            return json(["width": q.width, "height": q.height, "fps": q.fps])

        case "playback":
            if let draft {
                // Nothing plays during a Magic edit; seeking moves get_frame's default time.
                if args["action"] as? String == "seek" { draft.playhead = max(0, try numArg(args, "time")) }
                return text("Playhead at \(String(format: "%.3f", draft.playhead))s. Playback is off while making a Magic edit; use get_frame to see the cut.")
            }
            switch args["action"] as? String {
            case "play": model.play()
            case "pause": model.pause()
            case "seek": model.seek(to: max(0, try numArg(args, "time")))
            default: throw MCPToolError("action is play, pause or seek.")
            }
            return text("Playhead at \(String(format: "%.3f", model.playhead))s, \(model.isPlaying ? "playing" : "paused").")

        case "history":
            if let draft {
                switch args["action"] as? String {
                case "undo":
                    guard draft.canUndo else { throw MCPToolError("Nothing to undo.") }
                    draft.undo()
                case "redo":
                    guard draft.canRedo else { throw MCPToolError("Nothing to redo.") }
                    draft.redo()
                default: throw MCPToolError("action is undo or redo.")
                }
                return text("Done. \(draft.project.clips.count) clips on the timeline.")
            }
            switch args["action"] as? String {
            case "undo":
                guard model.canUndo else { throw MCPToolError("Nothing to undo.") }
                model.undo()
            case "redo":
                guard model.canRedo else { throw MCPToolError("Nothing to redo.") }
                model.redo()
            default: throw MCPToolError("action is undo or redo.")
            }
            return text("Done. \(model.project.clips.count) clips on the timeline.")

        case "auto_edit":
            try notInMagic()
            while MagicShow.isRunning || MagicState.shared.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
            MagicShow.start(model: model, fromMouse: false)
            try? await Task.sleep(nanoseconds: 100_000_000)
            while MagicShow.isRunning || MagicState.shared.busy { try? await Task.sleep(nanoseconds: 100_000_000) }
            return json(projectJSON(model.project, title: model.title, playhead: model.playhead))

        case "save_project":
            try notInMagic()
            guard model.fileURL != nil else { throw MCPToolError("This project has never been saved; ask the person to save it (File > Save).") }
            model.save()
            return text("Saved.")

        default:
            throw MCPToolError("No tool called \(name).")
        }
    }

    // MARK: Performing

    /// Plays edits with the agent's cursor and waits until they're done; during a Magic edit, just
    /// makes them in the draft.
    private static func perform(_ edits: [MagicEdit], _ model: EditorModel, _ who: String, _ draft: MCPDraft?) async throws {
        if let draft { return draft.apply(edits) }
        reveal(edits, model)
        let color = Self.color(for: who)
        let start = AgentPresence.shared.take(who)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await MagicShow.perform(model: model, edits: edits, as: MagicShow.Performer(name: who, color: color, start: start) { _ in
                    cont.resume()
                })
            }
        }
    }

    /// Scrolls the timeline so what's being edited is in view.
    private static func reveal(_ edits: [MagicEdit], _ model: EditorModel) {
        var times: [Double] = []
        for e in edits {
            switch e {
            case .place(let clips, _): times += clips.flatMap { [$0.start, $0.end] }
            case .move(_, let from, let to, _): times += [from, to]
            case .trimHead(_, let from, let to), .trimTail(_, let from, let to): times += [from, to]
            case .blade(_, let at, _, _): times.append(at)
            default: times += e.clipIDs.compactMap { model.project.clip($0) }.flatMap { [$0.start, $0.end] }
            }
        }
        guard let lo = times.min(), let hi = times.max() else { return }
        let v = model.view
        let first = Double(v.scrollX / v.pps), last = Double((v.scrollX + v.viewWidth) / v.pps)
        guard lo < first || hi > last else { return }
        if hi - lo > last - first {
            model.setView(pps: (v.viewWidth - 80) / CGFloat(max(1, hi - lo)), scrollX: CGFloat(lo) * ((v.viewWidth - 80) / CGFloat(max(1, hi - lo))) - 40)
        } else {
            model.setView(scrollX: CGFloat(lo) * v.pps - v.viewWidth * 0.2)
        }
    }

    /// Claude in its orange, OpenAI's agents in their green, anyone else in a colour of their own.
    static func color(for name: String) -> NSColor {
        switch name {
        case "Claude": return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case "Codex", "ChatGPT": return NSColor(srgbRed: 0.06, green: 0.64, blue: 0.50, alpha: 1)
        default:
            var h: UInt64 = 1469598103934665603
            for b in name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            return NSColor(hue: CGFloat(h % 360) / 360, saturation: 0.65, brightness: 0.95, alpha: 1)
        }
    }

    // MARK: Arguments

    private static func numArg(_ args: [String: Any], _ key: String) throws -> Double {
        if let d = args[key] as? Double { return d }
        if let i = args[key] as? Int { return Double(i) }
        throw MCPToolError("\(key) is needed, in seconds.")
    }

    private static func assetArg(_ args: [String: Any], _ p: Project) throws -> MediaAsset {
        guard let s = args["asset_id"] as? String else { throw MCPToolError("asset_id is needed (see list_media).") }
        guard let a = p.assets.first(where: { $0.id.uuidString == s.uppercased() || $0.name == s }) else {
            throw MCPToolError("No library item with id \(s). list_media has them.")
        }
        return a
    }

    private static func clipArg(_ args: [String: Any], _ p: Project) throws -> Clip {
        guard let s = args["clip_id"] as? String else { throw MCPToolError("clip_id is needed (see get_project).") }
        guard let id = UUID(uuidString: s), let c = p.clip(id) else { throw MCPToolError("No clip with id \(s). get_project has them.") }
        guard !p.isLocked(c.trackID) else { throw MCPToolError("That clip is on a locked track.") }
        return c
    }

    private static func trackArg(_ name: String, _ p: Project, kind: TrackKind) throws -> UUID {
        let n = name.uppercased().trimmingCharacters(in: .whitespaces)
        let prefix = kind == .video ? "V" : "A"
        guard n.hasPrefix(prefix), let i = Int(n.dropFirst()), i >= 1 else {
            throw MCPToolError("\(name) isn't a \(kind == .video ? "video track (V1, V2…)" : "audio track (A1, A2…)").")
        }
        let tracks = p.tracks(kind)
        guard i <= tracks.count else { throw MCPToolError("There's no \(n); there are \(tracks.count). add_track adds one.") }
        guard !tracks[i - 1].locked else { throw MCPToolError("\(n) is locked.") }
        return tracks[i - 1].id
    }

    // MARK: JSON

    /// Three decimal places, written as such ("5.417", not "5.4169999999999998").
    private static func round3(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", v)) }

    static func trackName(_ id: UUID, _ p: Project) -> String {
        if let i = p.trackIndex(id, kind: .video) { return "V\(i + 1)" }
        if let i = p.trackIndex(id, kind: .audio) { return "A\(i + 1)" }
        return "?"
    }

    private static func assetJSON(_ a: MediaAsset) -> [String: Any] {
        var d: [String: Any] = ["id": a.id.uuidString, "name": a.name, "kind": a.kind.rawValue, "path": a.path]
        if a.kind != .image { d["duration"] = round3(a.duration) }
        if a.kind != .audio { d["width"] = a.width; d["height"] = a.height }
        if a.kind == .video { d["fps"] = round3(a.fps); d["has_audio"] = a.hasAudio }
        return d
    }

    private static func clipsJSON(_ ids: [UUID], _ p: Project) -> [[String: Any]] {
        ids.compactMap { p.clip($0) }.map { clipJSON($0, p) }
    }

    private static func clipJSON(_ c: Clip, _ p: Project) -> [String: Any] {
        var d: [String: Any] = ["id": c.id.uuidString, "name": p.name(of: c), "kind": c.kind.rawValue, "track": trackName(c.trackID, p),
                                "start": round3(c.start), "end": round3(c.end), "duration": round3(c.duration)]
        if c.kind.usesSource { d["source_start"] = round3(c.sourceStart); d["asset_id"] = c.assetID?.uuidString ?? "" }
        if c.speed != 1 { d["speed"] = c.speed }
        if c.isReversed { d["reversed"] = true }
        if c.isFreeze { d["freeze_frame"] = true }
        if let link = c.linkID, let other = p.clips.first(where: { $0.linkID == link && $0.id != c.id }) { d["linked_to"] = other.id.uuidString }
        if c.kind == .audio || c.gainDB != 0 { d["gain_db"] = round3(c.gainDB) }
        if c.fadeIn > 0 { d["fade_in"] = round3(c.fadeIn) }
        if c.fadeOut > 0 { d["fade_out"] = round3(c.fadeOut) }
        if let t = c.transitionIn { d["transition_in"] = ["kind": t.kind.rawValue, "duration": t.duration] }
        if c.kind == .text { d["text"] = c.text.string }
        if let g = c.grade {
            var gd: [String: Any] = [:]
            if let look = g.look { gd["look"] = g.lookLabel; if look != g.lookLabel { gd["look_file"] = look } }
            if g.lookIntensity != 1 { gd["look_intensity"] = g.lookIntensity }
            for (k, v) in [("exposure", g.exposure), ("contrast", g.contrast), ("saturation", g.saturation), ("temperature", g.temperature), ("tint", g.tint)] where v != 0 {
                gd[k] = round3(v)
            }
            d["grade"] = gd
        }
        return d
    }

    /// A new empty track with a known id, so the same edit makes the same track when it's played back.
    private static func addTrackEdit(_ kind: TrackKind, id: UUID) -> MagicEdit {
        .change(nil, kind == .video ? "Add video track" : "Add audio track") { proj in
            var t = Track(kind: kind)
            t.id = id
            if kind == .video { proj.videoTracks.append(t) } else { proj.audioTracks.append(t) }
        }
    }

    private static func projectJSON(_ p: Project, title: String, playhead: Double) -> [String: Any] {
        let tracks = p.videoTracks.enumerated().reversed().map { i, t in
            ["name": "V\(i + 1)", "kind": "video", "hidden": t.hidden, "locked": t.locked] as [String: Any]
        } + p.audioTracks.enumerated().map { i, t in
            ["name": "A\(i + 1)", "kind": "audio", "muted": t.muted, "solo": t.solo, "locked": t.locked, "gain_db": t.gainDB] as [String: Any]
        }
        let clips = p.clips.sorted {
            (trackName($0.trackID, p), $0.start) < (trackName($1.trackID, p), $1.start)
        }.map { clipJSON($0, p) }
        return [
            "name": title,
            "sequence": ["width": p.width, "height": p.height, "fps": p.fps, "duration": round3(p.duration)],
            "playhead": round3(playhead),
            "tracks": tracks,
            "clips": clips,
            "markers": p.markerList.map { ["time": round3($0.time), "name": $0.name] },
        ]
    }
}
