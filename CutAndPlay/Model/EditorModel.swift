import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum Tool { case move, cut }

enum DragPayload: Equatable {
    case asset(UUID)
    case solid
    case text
}

/// Zoom and scroll of the timeline. Kept separate so scrolling doesn't invalidate the whole UI.
@MainActor
final class TimelineViewState: ObservableObject {
    static let minPPS: CGFloat = 0.05
    static let maxPPS: CGFloat = 2400

    @Published var pps: CGFloat = 80
    @Published var scrollX: CGFloat = 0
    @Published var scrollY: CGFloat = 0
    @Published var rowHeight: CGFloat = 62
    @Published var viewWidth: CGFloat = 900
    @Published var viewHeight: CGFloat = 300
    /// Set until the timeline has reported its real size and the tracks have been centred in it.
    var needsInitialCentering = true

    static let rowRange: ClosedRange<CGFloat> = 30...110
}

/// Publishes only when the visible frame number changes.
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var frame = 0

    func update(time: Double, fps: Double) {
        let f = Int((time * fps).rounded())
        if f != frame { frame = f }
    }
}

struct SavedDocument: Codable {
    var version = 1
    var project: Project
}

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var project = Project() {
        didSet { lastEdit = Date() }
    }
    @Published var selection: Set<UUID> = []
    @Published var tool: Tool = .move
    @Published var snapping = true
    /// Skimming: hovering over the timeline shows that frame in the viewer without moving the playhead.
    @Published var skimming = UserDefaults.standard.object(forKey: "skimming") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(skimming, forKey: "skimming")
            if !skimming { skim(to: nil) }
        }
    }
    /// Where the viewer is skimmed to, if anywhere.
    private(set) var skimTime: Double?
    /// Audio scrubbing: hear short snippets while dragging the playhead or skimming. Off unless turned on.
    @Published var audioScrub = UserDefaults.standard.bool(forKey: "audioScrub") {
        didSet {
            UserDefaults.standard.set(audioScrub, forKey: "audioScrub")
            if audioScrub {
                scrubber.warmUp()
                scrubber.prepare(project: project, media: media)
            } else {
                scrubber.shutDown()
            }
        }
    }
    private let scrubber = AudioScrubber()
    /// The last snippet heard, so the meters can show it.
    private var lastScrubSound: (time: Double, at: Double)?

    /// Plays a snippet of the timeline's sound at a time, when audio scrubbing is on.
    func scrubSound(at t: Double) {
        guard audioScrub, !isPlaying else { return }
        scrubber.play(at: t)
        lastScrubSound = (t, CACurrentMediaTime())
    }
    /// Sticky edges: clips touching a clip that changes length move with it, closing or opening up
    /// the space instead of leaving a gap or overlapping.
    @Published var sticky = UserDefaults.standard.bool(forKey: "stickyEdges") {
        didSet { UserDefaults.standard.set(sticky, forKey: "stickyEdges") }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published var showExport = false
    /// Playback starts over from the beginning when it reaches the end.
    @Published var loop = UserDefaults.standard.bool(forKey: "loopPlayback") {
        didSet { UserDefaults.standard.set(loop, forKey: "loopPlayback") }
    }
    /// Only the viewer is shown, full screen.
    @Published private(set) var viewerOnly = false
    @Published private(set) var importCount = 0
    @Published var importError: String?

    let view = TimelineViewState()
    let clock = Clock()
    let media = MediaStore()
    let meters = MeterState()
    let sourcePreview = SourcePreviewState()
    let engine = PlaybackEngine()
    let exports = ExportQueue()

    private(set) var playhead: Double = 0
    var tickHandlers: [() -> Void] = []
    /// Set while something is being dragged out of the library.
    var dragPayload: DragPayload?

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var liveSnapshot: Project?
    private var liveTimer: Timer?
    private var rebuildPending = false
    private var lastRebuild = 0.0

    init() {
        engine.onEnded = { [weak self] in
            guard let self else { return }
            if self.loop, self.project.duration > 0 {
                self.playhead = 0
                self.engine.seek(to: 0)
                self.engine.play()
                return
            }
            self.isPlaying = false
            self.playhead = self.project.duration
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // Leaving macOS full screen while the viewer had it: back to the editor.
                if self?.viewerOnly == true, let window = note.object as? NSWindow {
                    self?.viewerOnly = false
                    ViewerScreen.exit(window)
                }
            }
        }
        media.onStillLoaded = { [weak self] in self?.setNeedsRebuild() }
        Task {
            await BaseVideo.load()
            self.setNeedsRebuild()
            // `--open <project.cutplay>` loads a project at launch.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--open"), args.count > i + 1 {
                self.open(url: URL(fileURLWithPath: args[i + 1]))
                if let j = args.firstIndex(of: "--seek"), args.count > j + 1, let t = Double(args[j + 1]) {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.seek(to: t)
                }
                if args.contains("--select-first"), let first = self.project.clips.first {
                    self.selection = self.project.linked([first.id])
                }
                if args.contains("--show-export") { self.showExport = true }
                if args.contains("--play") { self.play() }
                if args.contains("--curve-menu") {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let (menu, current) = CurveMenu.menu(selection: .easeIn, rising: true) { _ in }
                    menu.popUp(positioning: current, at: NSPoint(x: 400, y: 600), in: nil)
                }
                // `--queue-exports <dir>`: queues a 4K HEVC and a WAV export, for checking the queue.
                if let k = args.firstIndex(of: "--queue-exports"), args.count > k + 1 {
                    let dir = URL(fileURLWithPath: args[k + 1])
                    var video = ExportSettings()
                    video.height = 2160
                    video.codec = .hevc
                    var audio = ExportSettings()
                    audio.format = .wav
                    self.exports.add(project: self.project, media: self.media, settings: video, url: dir.appendingPathComponent("queued_4k.mp4"))
                    self.exports.add(project: self.project, media: self.media, settings: audio, url: dir.appendingPathComponent("queued.wav"))
                }
                if args.contains("--viewer-fullscreen") {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.toggleViewerFullScreen()
                }
            } else if !args.contains("--selftest") {
                self.restoreLastSession()
            }
        }
        if audioScrub { scrubber.warmUp() }
        if !CommandLine.arguments.contains("--selftest") {
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autosaveIfIdle() }
            }
        }
    }

    // MARK: Autosave and recovery

    private var autosaveTimer: Timer?
    private var lastEdit = Date.distantPast
    private var lastRecovered: Project?

    /// Unsaved work on an untitled project is kept here, and reopened on the next launch.
    static var recoveryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CutAndPlay/Recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Untitled.cutplay")
    }

    /// What to reopen at launch: a project file's path, or "untitled" for the recovery copy.
    private var lastSession: String? {
        get { UserDefaults.standard.string(forKey: "lastSession") }
        set {
            guard !CommandLine.arguments.contains("--open") else { return }
            UserDefaults.standard.set(newValue, forKey: "lastSession")
        }
    }

    /// Two seconds after the last change, and never in the middle of a drag: a saved project is
    /// saved in place, and untitled work goes to the recovery copy.
    private func autosaveIfIdle() {
        guard isDirty, liveSnapshot == nil, Date().timeIntervalSince(lastEdit) > 2 else { return }
        autosaveNow()
    }

    func autosaveNow() {
        commitLive()
        if let url = fileURL {
            guard isDirty else { return }
            write(to: url)
            lastSession = url.path
        } else if project.clips.isEmpty && project.assets.isEmpty {
            try? FileManager.default.removeItem(at: Self.recoveryURL)
            if lastSession == "untitled" { lastSession = nil }
        } else if lastRecovered != project {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(SavedDocument(project: project)) {
                try? data.write(to: Self.recoveryURL, options: .atomic)
                lastRecovered = project
                lastSession = "untitled"
            }
        }
    }

    /// Opens whatever was being worked on last time: the project file, or untitled work from the
    /// recovery copy. Nothing to reopen leaves the empty project that's already there.
    private func restoreLastSession() {
        guard let last = lastSession else { return }
        if last == "untitled" {
            guard let data = try? Data(contentsOf: Self.recoveryURL),
                  let doc = try? JSONDecoder().decode(SavedDocument.self, from: data) else { return }
            load(doc.project, url: nil, offerLocate: true)
            lastRecovered = doc.project
            isDirty = true
        } else if FileManager.default.fileExists(atPath: last) {
            open(url: URL(fileURLWithPath: last))
        }
    }

    func open(url: URL) {
        do {
            var doc = try JSONDecoder().decode(SavedDocument.self, from: Data(contentsOf: url))
            doc.project.resolveMovedMedia(projectDir: url.deletingLastPathComponent())
            load(doc.project, url: url, offerLocate: true)
            noteRecent(url)
            // Test launches (`--open`, `--selftest`) don't change what opens next time.
            if !CommandLine.arguments.contains("--selftest"), !CommandLine.arguments.contains("--open") { lastSession = url.path }
        } catch {
            importError = "Couldn't open \(url.lastPathComponent)."
        }
    }

    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    var canUndo: Bool { !undoStack.isEmpty || liveSnapshot != nil }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Mutation & undo

    /// One undoable change.
    func mutate(_ body: (inout Project) -> Void) {
        commitLive()
        var p = project
        body(&p)
        p.sanitize()
        guard p != project else { return }
        undoStack.append(project)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        project = p
        didChange()
    }

    /// Continuous change (drag, slider). Coalesces into a single undo step.
    func live(autoCommit: Bool = true, _ body: (inout Project) -> Void) {
        var p = project
        body(&p)
        guard p != project else { return }
        if liveSnapshot == nil { liveSnapshot = project }
        project = p
        isDirty = true
        setNeedsRebuild()
        liveTimer?.invalidate()
        liveTimer = nil
        if autoCommit {
            liveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.commitLive() }
            }
        }
    }

    func commitLive() {
        liveTimer?.invalidate()
        liveTimer = nil
        guard let snapshot = liveSnapshot else { return }
        liveSnapshot = nil
        if snapshot != project {
            undoStack.append(snapshot)
            redoStack.removeAll()
        }
    }

    func undo() {
        commitLive()
        guard var prev = undoStack.popLast() else { return }
        redoStack.append(project)
        prev.assets = project.assets
        project = prev
        didChange()
    }

    func redo() {
        commitLive()
        guard var next = redoStack.popLast() else { return }
        undoStack.append(project)
        next.assets = project.assets
        project = next
        didChange()
    }

    private func didChange() {
        let valid = selection.intersection(Set(project.clips.map(\.id)))
        if valid != selection { selection = valid }
        isDirty = true
        // Adding or removing a video track moves the video/audio gap; keep it where it was on screen.
        let above = rowsAbove
        if lastRowsAbove > 0, above != lastRowsAbove {
            setView(scrollY: view.scrollY + above - lastRowsAbove)
        } else {
            clampView()
        }
        setNeedsRebuild()
    }

    func setNeedsRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        let wait = max(0, 0.03 - (CACurrentMediaTime() - lastRebuild))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.rebuildNow() }
        }
    }

    private func rebuildNow() {
        guard rebuildPending else { return }
        rebuildPending = false
        lastRebuild = CACurrentMediaTime()
        engine.rebuild(project: project, media: media, at: playhead)
        if audioScrub { scrubber.prepare(project: project, media: media) }
        if isPlaying && engine.isEmpty { isPlaying = false }
    }

    // MARK: Transport

    func tick() {
        if isPlaying {
            playhead = min(engine.currentTime, max(engine.duration, 0))
            // Within a frame of the end, or stopped by the player: start over when looping.
            let end = project.duration
            if loop, end > 0, playhead >= end - 1 / project.fps || !engine.isPlaying {
                playhead = 0
                engine.seek(to: 0)
                engine.play()
            }
        }
        clock.update(time: playhead, fps: project.fps)
        // While scrubbing with sound, the meters show what's being heard.
        if !isPlaying, let s = lastScrubSound, CACurrentMediaTime() - s.at < AudioScrubber.snippet + 0.05 {
            meters.update(project: project, media: media, time: s.time, playing: true, quickRelease: true)
        } else {
            meters.update(project: project, media: media, time: playhead, playing: isPlaying)
        }
        for handler in tickHandlers { handler() }
    }

    /// Shows just the viewer, full screen, or goes back to the editor.
    func toggleViewerFullScreen() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        viewerOnly.toggle()
        if viewerOnly { ViewerScreen.enter(window) } else { ViewerScreen.exit(window) }
        // The viewer is rebuilt in its new place; give it a frame to show while paused.
        if !isPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.engine.seek(to: self.playhead)
            }
        }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// Shows the frame at a time without moving the playhead; nil goes back to the playhead's frame.
    func skim(to t: Double?) {
        guard let t else {
            if skimTime != nil {
                skimTime = nil
                if !isPlaying { engine.seek(to: playhead) }
            }
            return
        }
        guard skimming, !isPlaying else { return }
        let time = min(max(0, project.snapFrame(t)), project.duration)
        guard time != skimTime else { return }
        skimTime = time
        engine.seek(to: time)
        scrubSound(at: time)
    }

    func play() {
        skimTime = nil
        guard project.duration > 0 else { return }
        rebuildNow()
        guard !engine.isEmpty else { return }
        if playhead >= project.duration - 1 / project.fps {
            playhead = 0
            engine.seek(to: 0)
        }
        engine.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        engine.pause()
        isPlaying = false
        playhead = project.snapFrame(engine.currentTime)
        engine.seek(to: playhead)
    }

    func seek(to time: Double) {
        skimTime = nil
        if isPlaying {
            engine.pause()
            isPlaying = false
        }
        playhead = max(0, project.snapFrame(time))
        engine.seek(to: playhead)
    }

    func step(frames: Int) {
        seek(to: playhead + Double(frames) / project.fps)
    }

    func jumpToEdit(forward: Bool) {
        let points = project.editPoints
        let eps = 0.5 / project.fps
        if forward {
            if let t = points.first(where: { $0 > playhead + eps }) { seek(to: t) }
        } else {
            if let t = points.last(where: { $0 < playhead - eps }) { seek(to: t) }
        }
    }

    // MARK: Zoom

    // Every change to zoom or scroll goes through `setView`, so the canvas, the scroll bars and the
    // wheel all agree on one set of limits and nothing can fight over the position.

    /// Seconds of timeline that can be scrolled to: the content plus working room after it.
    var extent: Double { max(30, project.duration * 1.3 + 10) }

    /// Fully zoomed out shows exactly `extent`.
    var minPPS: CGFloat { max(TimelineViewState.minPPS, view.viewWidth / CGFloat(extent)) }
    var maxScrollX: CGFloat { max(0, CGFloat(extent) * view.pps - view.viewWidth) }

    var rowsContent: CGFloat {
        TimelineLayout.fixedHeight + CGFloat(project.videoTracks.count + project.audioTracks.count) * (view.rowHeight + TimelineLayout.gap)
    }
    var rowsVisible: CGFloat { max(40, view.viewHeight - TimelineLayout.ruler) }

    /// Distance from the top of the tracks to the middle of the gap between video and audio.
    /// That gap is the vertical "home" of the timeline: the centre of the scroll bar.
    var rowsAbove: CGFloat {
        TimelineLayout.zone + CGFloat(project.videoTracks.count) * (view.rowHeight + TimelineLayout.gap) + TimelineLayout.divider / 2
    }

    /// The vertical bar is a window onto a taller "world" whose middle is the video/audio gap, so a
    /// centred thumb always puts that gap in the middle of the view, however many tracks are on
    /// either side. The world is at least big enough to reach both ends of the tracks, and grows as
    /// rows get taller so the thumb's length shows the zoom.
    var rowsWorld: CGFloat {
        let zoomed = rowsVisible * view.rowHeight / TimelineViewState.rowRange.lowerBound
        return max(rowsVisible, zoomed, 2 * rowsAbove, 2 * (rowsContent - rowsAbove))
    }

    /// Fraction of the vertical bar the thumb covers.
    var rowWindow: CGFloat { rowsVisible / rowsWorld }

    /// The same fraction as it would be at another row height.
    func rowWindow(rowHeight r: CGFloat) -> CGFloat {
        let tracks = CGFloat(project.videoTracks.count + project.audioTracks.count)
        let above = TimelineLayout.zone + CGFloat(project.videoTracks.count) * (r + TimelineLayout.gap) + TimelineLayout.divider / 2
        let content = TimelineLayout.fixedHeight + tracks * (r + TimelineLayout.gap)
        let zoomed = rowsVisible * r / TimelineViewState.rowRange.lowerBound
        return rowsVisible / max(rowsVisible, zoomed, 2 * above, 2 * (content - above))
    }

    /// `scrollY` is how far the top of the tracks is above the top of the view; it goes negative
    /// when the tracks sit lower than the top.
    var minScrollY: CGFloat { rowsAbove - rowsWorld / 2 }
    var maxScrollY: CGFloat { rowsAbove + rowsWorld / 2 - rowsVisible }
    var centeredScrollY: CGFloat { rowsAbove - rowsVisible / 2 }

    func centerRows() {
        setView(scrollY: centeredScrollY)
    }

    func setView(pps: CGFloat? = nil, scrollX: CGFloat? = nil, scrollY: CGFloat? = nil, rowHeight: CGFloat? = nil) {
        if let rowHeight {
            let r = min(TimelineViewState.rowRange.upperBound, max(TimelineViewState.rowRange.lowerBound, rowHeight.rounded()))
            if r != view.rowHeight { view.rowHeight = r }
        }
        let p = min(TimelineViewState.maxPPS, max(minPPS, pps ?? view.pps))
        if p != view.pps { view.pps = p }
        let x = min(max(0, scrollX ?? view.scrollX), maxScrollX)
        if x != view.scrollX { view.scrollX = x }
        let y = min(max(minScrollY, scrollY ?? view.scrollY), maxScrollY)
        if y != view.scrollY { view.scrollY = y }
        lastRowsAbove = rowsAbove
    }

    func clampView() { setView() }

    private var lastRowsAbove: CGFloat = 0

    /// Zooms around the playhead: it keeps its place on screen, or is brought to the centre if it was off screen.
    func setZoom(_ newPPS: CGFloat) {
        let old = view.pps
        let pps = min(TimelineViewState.maxPPS, max(minPPS, newPPS))
        guard abs(pps - old) > 1e-9 else { return }
        let px = CGFloat(playhead) * old - view.scrollX
        let anchor = (px >= 0 && px <= view.viewWidth) ? px : view.viewWidth / 2
        setView(pps: pps, scrollX: CGFloat(playhead) * pps - anchor)
    }

    func zoom(by factor: CGFloat) {
        setZoom(view.pps * factor)
    }

    func zoomToFit() {
        let d = max(project.duration, 1)
        setView(pps: (view.viewWidth - 80) / CGFloat(d), scrollX: 0)
    }

    // MARK: Import

    static var importTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audio, .image, .audiovisualContent]
        for ext in ["mkv", "webm", "avi", "flv", "wmv", "mts", "m2ts", "ts", "mxf", "ogv", "ogg", "opus", "flac", "3gp", "mpg", "mpeg", "vob", "f4v"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.importTypes
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL], then completion: (([MediaAsset]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        importCount += urls.count
        Task {
            var imported: [MediaAsset] = []
            var failed: [String] = []
            for url in urls {
                if let existing = project.assets.first(where: { $0.path == url.path }) {
                    imported.append(existing)
                } else if let asset = await media.importFile(url) {
                    project.assets.append(asset)
                    isDirty = true
                    imported.append(asset)
                    offerMatch(asset)
                } else {
                    failed.append(url.lastPathComponent)
                }
                importCount -= 1
            }
            if !failed.isEmpty {
                let hint = FFmpeg.binary == nil ? " Install ffmpeg to import formats macOS can't decode." : ""
                importError = "Couldn't import " + failed.joined(separator: ", ") + "." + hint
            }
            completion?(imported)
        }
    }

    /// Asked once, on the first video brought into a project: adopt its frame size and rate?
    private func offerMatch(_ asset: MediaAsset) {
        guard asset.kind == .video, !project.settingsLocked, asset.width > 0, asset.height > 0 else { return }
        let fps = Self.standardFPS(asset.fps)
        project.settingsLocked = true
        if asset.width == project.width, asset.height == project.height, fps == project.fps { return }
        let alert = NSAlert()
        alert.messageText = "Match the sequence to “\(asset.name)”?"
        alert.informativeText = "\(asset.width) × \(asset.height) · \(InspectorView.fpsLabel(fps))\nThe sequence is currently \(project.width) × \(project.height) · \(InspectorView.fpsLabel(project.fps))."
        alert.addButton(withTitle: "Match")
        alert.addButton(withTitle: "Keep Current")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mutate { p in
            p.width = asset.width
            p.height = asset.height
            p.fps = fps
        }
    }

    /// Remembers where exports go. Not an undoable edit.
    func setExportTarget(name: String, directory: String) {
        guard project.exportName != name || project.exportDir != directory else { return }
        project.exportName = name
        project.exportDir = directory
        isDirty = true
    }

    /// Renders the frame under the playhead, for previews.
    func snapshot() async -> NSImage? {
        let p = project
        let scale = min(1, 640 / CGFloat(max(p.width, p.height)))
        let size = CGSize(width: max(2, (CGFloat(p.width) * scale / 2).rounded() * 2),
                          height: max(2, (CGFloat(p.height) * scale / 2).rounded() * 2))
        guard let built = CompositionBuilder.build(project: p, media: media, renderSize: size, includeAudio: false) else { return nil }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let t = min(max(0, playhead), max(0, built.duration - 1 / p.fps))
        guard let cg = try? await generator.image(at: CompositionBuilder.time(t)).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    func removeAsset(_ id: UUID) {
        commitLive()
        project.clips.removeAll { $0.assetID == id }
        project.assets.removeAll { $0.id == id }
        media.forget(id)
        undoStack.removeAll()
        redoStack.removeAll()
        didChange()
    }

    // MARK: Adding clips

    func payloadDuration(_ payload: DragPayload) -> Double {
        if case .asset(let id) = payload, let a = project.asset(id), a.kind != .image {
            return max(1 / project.fps, floor(a.duration * project.fps + 1e-6) / project.fps)
        }
        return 5
    }

    /// Builds the clip (or linked video + audio pair) a payload produces.
    func makeClips(_ payload: DragPayload, at start: Double, videoTrack: UUID, audioTrack: UUID) -> [Clip] {
        let dur = payloadDuration(payload)
        switch payload {
        case .solid:
            return [Clip(trackID: videoTrack, kind: .solid, start: start, duration: dur)]
        case .text:
            return [Clip(trackID: videoTrack, kind: .text, start: start, duration: dur)]
        case .asset(let id):
            guard let a = project.asset(id) else { return [] }
            switch a.kind {
            case .image:
                return [Clip(trackID: videoTrack, kind: .image, assetID: id, start: start, duration: dur)]
            case .audio:
                return [Clip(trackID: audioTrack, kind: .audio, assetID: id, start: start, duration: dur)]
            case .video:
                var v = Clip(trackID: videoTrack, kind: .video, assetID: id, start: start, duration: dur)
                guard a.hasAudio else { return [v] }
                let link = UUID()
                v.linkID = link
                var au = Clip(trackID: audioTrack, kind: .audio, assetID: id, start: start, duration: dur)
                au.linkID = link
                return [v, au]
            }
        }
    }

    func insert(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        let ids = Set(clips.map(\.id))
        mutate { p in
            p.clips.append(contentsOf: clips)
            p.materializeTokens()
            p.resolveOverlaps(keeping: ids)
        }
        selection = ids
    }

    func addAtPlayhead(_ payload: DragPayload) {
        let dur = payloadDuration(payload)
        // Text and solids never cover anything: the first open video track at the playhead, or else
        // the first gap after it.
        if payload == .text || payload == .solid {
            if let spot = project.firstFreeVideoSpot(from: playhead, duration: dur) {
                insert(makeClips(payload, at: spot.start, videoTrack: spot.track, audioTrack: project.audioTracks.first?.id ?? TrackToken.newAudio))
            } else {
                insert(makeClips(payload, at: playhead, videoTrack: TrackToken.newVideo, audioTrack: TrackToken.newAudio))
            }
            return
        }
        let start = playhead
        let v = project.freeTrack(.video, start: start, duration: dur) ?? TrackToken.newVideo
        let a = project.freeTrack(.audio, start: start, duration: dur) ?? TrackToken.newAudio
        insert(makeClips(payload, at: start, videoTrack: v, audioTrack: a))
    }

    static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    static func standardFPS(_ fps: Double) -> Double {
        guard fps > 1 else { return 30 }
        if fps > 61 { return 60 }
        return frameRates.min { abs($0 - fps) < abs($1 - fps) } ?? 30
    }

    // MARK: Editing commands

    func deleteSelection(ripple: Bool = false) {
        guard !selection.isEmpty else { return }
        let ids = project.unlocked(project.linked(selection))
        guard !ids.isEmpty else { return }
        mutate { $0.remove(ids: ids, ripple: ripple) }
    }

    func splitAtPlayhead() {
        let t = playhead
        let under = project.clips.filter { $0.start < t && $0.end > t }
        let selected = under.filter { selection.contains($0.id) }
        let targets = project.unlocked(project.linked(Set((selected.isEmpty ? under : selected).map(\.id))))
        guard !targets.isEmpty else { return }
        mutate { p in _ = p.split(ids: targets, at: t) }
    }

    func split(clip id: UUID, at t: Double) {
        let targets = project.linked([id])
        mutate { p in _ = p.split(ids: targets, at: t) }
    }

    func detachAudio() {
        let ids = selection
        mutate { $0.unlink(ids: ids) }
    }

    var selectionIsLinked: Bool {
        project.clips.contains { selection.contains($0.id) && $0.linkID != nil }
    }

    func selectAll() {
        selection = Set(project.clips.map(\.id))
    }

    // MARK: Freeze frame

    /// Holds the frame under the playhead for two seconds: the clip splits there, a freeze frame goes
    /// in, and everything after it on the clip's tracks moves along to make room.
    func freezeFrame(seconds hold: Double = 2) {
        let t = project.snapFrame(playhead)
        let under = project.clips.filter { $0.kind == .video && !$0.isFreeze && !project.isLocked($0.trackID) && t >= $0.start && t < $0.end }
        let chosen = under.first { selection.contains($0.id) } ?? under.max { a, b in
            (project.trackIndex(a.trackID, kind: .video) ?? 0) < (project.trackIndex(b.trackID, kind: .video) ?? 0)
        }
        guard let c = chosen else { return }
        let source = c.sourceStart + (t - c.start) * c.speed
        var made: UUID?
        mutate { p in
            let group = p.linked([c.id])
            _ = p.split(ids: group, at: t)
            let tracks = Set(p.clips.filter { group.contains($0.id) }.map(\.trackID))
            var shifting = Set(p.clips.filter { tracks.contains($0.trackID) && $0.start >= t - 1e-6 }.map(\.id))
            shifting = p.unlocked(p.linked(shifting))
            for i in p.clips.indices where shifting.contains(p.clips[i].id) { p.clips[i].start += hold }
            var f = Clip(trackID: c.trackID, kind: .video, assetID: c.assetID, start: t, duration: hold, sourceStart: source)
            f.freeze = true
            f.grade = c.grade
            f.transform = c.transform
            p.clips.append(f)
            p.resolveOverlaps(keeping: shifting.union([f.id]))
            made = f.id
        }
        if let made { selection = [made] }
    }

    // MARK: Reverse

    /// Plays the selected clip (and its linked audio) backwards. The first time, the stretch it uses is
    /// rendered reversed into a new file in the background; reversing again switches straight back.
    func reverseSelection() {
        guard let c = project.clips.first(where: { selection.contains($0.id) && $0.playsSource && !project.isLocked($0.trackID) }) else { return }
        let group = project.unlocked(project.linked([c.id]))

        if let back = c.reversedFrom {
            // Already reversed: point back at the original footage.
            mutate { p in
                for i in p.clips.indices where group.contains(p.clips[i].id) {
                    guard let from = p.clips[i].reversedFrom else { continue }
                    p.clips[i].assetID = from.assetID
                    p.clips[i].sourceStart = from.sourceStart
                    p.clips[i].reversedFrom = nil
                }
            }
            _ = back
            return
        }

        guard let asset = project.asset(c.assetID) else { return }
        let members = project.clips.filter { group.contains($0.id) && $0.assetID == c.assetID && $0.playsSource }
        // One rendered stretch covering every member's source range.
        let lo = members.map(\.sourceStart).min() ?? c.sourceStart
        let hi = members.map { $0.sourceStart + $0.duration * $0.speed }.max() ?? (c.sourceStart + c.duration * c.speed)
        let name = asset.name + " (reversed)"
        let out = Reverser.folder.appendingPathComponent("\(asset.name)-\(UUID().uuidString.prefix(8)).mov")
        let ids = Set(members.map(\.id))
        importCount += 1
        Task {
            defer { importCount -= 1 }
            do {
                try await Reverser.render(source: asset.url, start: lo, duration: hi - lo, to: out) { _ in }
                guard var fresh = await media.importFile(out) else { throw Reverser.Failure(message: "Couldn't open the reversed clip.") }
                fresh.name = name
                let added = fresh
                mutate { p in
                    p.assets.append(added)
                    for i in p.clips.indices where ids.contains(p.clips[i].id) {
                        let m = p.clips[i]
                        p.clips[i].reversedFrom = ReverseSource(assetID: asset.id, sourceStart: m.sourceStart)
                        p.clips[i].assetID = added.id
                        // Source time s in the original is hi - s in the reversed file.
                        p.clips[i].sourceStart = max(0, hi - (m.sourceStart + m.duration * m.speed))
                    }
                }
            } catch is CancellationError {
            } catch {
                importError = "Couldn't reverse “\(asset.name)”: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Gaps

    func deleteGap(on track: UUID, at t: Double) {
        guard let g = project.gap(on: track, at: t) else { return }
        mutate { $0.pullLeft(on: track, from: g.end, by: g.end - g.start) }
    }

    /// Closes the gaps on the selected clips' tracks, or on every track with nothing selected.
    func closeAllGaps(on tracks: [UUID]? = nil) {
        let chosen = tracks ?? {
            let selected = Set(project.clips.filter { selection.contains($0.id) }.map(\.trackID))
            return selected.isEmpty ? (project.videoTracks + project.audioTracks).map(\.id) : Array(selected)
        }()
        mutate { p in for t in chosen { p.closeAllGaps(on: t) } }
    }

    // MARK: Copy, paste, duplicate

    /// Copied clips, with times measured from the earliest of them.
    private(set) var clipboard: [Clip] = []

    private var selectedForCopy: [Clip] {
        let ids = project.unlocked(project.linked(selection))
        return project.clips.filter { ids.contains($0.id) }
    }

    func copySelection() {
        let clips = selectedForCopy
        guard let t0 = clips.map(\.start).min() else { return }
        clipboard = clips.map { c in var c = c; c.start -= t0; return c }
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Pastes at the playhead, on the same tracks, over whatever is there (like Premiere), and moves
    /// the playhead to the end of what was pasted.
    func paste() {
        let copies = placed(clipboard, at: playhead)
        guard !copies.isEmpty else { return }
        insert(copies)
        if let end = copies.map(\.end).max() { seek(to: end) }
    }

    /// Puts a copy of the selection straight after it, on the same tracks.
    func duplicateSelection() {
        let clips = selectedForCopy
        guard let t0 = clips.map(\.start).min(), let t1 = clips.map(\.end).max() else { return }
        insert(placed(clips.map { c in var c = c; c.start -= t0; return c }, at: t1))
    }

    /// Fresh copies of clips (times relative to 0) placed at a time, with new ids and links kept
    /// between the copies. Copies whose track has gone or is locked land on an open track of their kind.
    func placed(_ clips: [Clip], at t: Double) -> [Clip] {
        var links: [UUID: UUID] = [:]
        return clips.map { original in
            var c = original
            c.id = UUID()
            if let l = c.linkID {
                if links[l] == nil { links[l] = UUID() }
                c.linkID = links[l]
            }
            c.start += t
            if project.track(c.trackID) == nil || project.isLocked(c.trackID) {
                let kind = c.kind.trackKind
                c.trackID = project.tracks(kind).first { !$0.locked }?.id ?? (kind == .video ? TrackToken.newVideo : TrackToken.newAudio)
            }
            return c
        }
    }

    /// Sets every selected audio clip (or every audio clip, with none selected) to the same typical
    /// level, so quiet and loud recordings sit together. Clips without a waveform yet are left alone.
    func evenOutLevels() {
        let target = -20.0
        let chosen = project.clips.filter { selection.contains($0.id) && $0.kind == .audio }
        let clips = (chosen.isEmpty ? project.clips.filter { $0.kind == .audio } : chosen).filter { !project.isLocked($0.trackID) }
        var gains: [UUID: Double] = [:]
        for c in clips {
            guard let level = AudioLevels.envelopeDB(c, media: media) else { continue }
            gains[c.id] = ((target - level) * 10).rounded() / 10
        }
        guard !gains.isEmpty else { return }
        mutate { p in
            for i in p.clips.indices {
                if let g = gains[p.clips[i].id] { p.clips[i].gainDB = g.clamped(to: -24...12) }
            }
        }
    }

    /// Turns one audio track down while another has sound (music under a voice); nil stops it.
    func duck(_ track: UUID, under voice: UUID?, amount: Double? = nil) {
        mutate { p in
            p.updateTrack(track) { t in
                t.duckUnder = voice
                if let amount { t.duckDB = amount }
            }
        }
    }

    /// Sets (or with nil removes) the transition into a clip from the one before it.
    func setTransition(into id: UUID, _ transition: Transition?) {
        mutate { p in
            if let i = p.index(of: id) { p.clips[i].transitionIn = transition }
        }
    }

    /// Puts a dissolve on the cut nearest the playhead, looking at selected clips first.
    func addTransitionAtPlayhead() {
        let cuts = project.clips.filter { c in
            c.kind != .audio && !project.isLocked(c.trackID) && project.previous(touching: c) != nil
        }
        let selected = cuts.filter { c in
            selection.contains(c.id) || project.previous(touching: c).map { selection.contains($0.id) } ?? false
        }
        guard let best = (selected.isEmpty ? cuts : selected).min(by: { abs($0.start - playhead) < abs($1.start - playhead) }) else { return }
        setTransition(into: best.id, best.transitionIn ?? Transition())
    }

    func setSpeed(_ speed: Double) {
        let ids = project.linked(selection)
        let sticky = self.sticky
        mutate { $0.setSpeed(ids: ids, speed: speed, sticky: sticky) }
    }

    func addTrack(_ kind: TrackKind) {
        mutate { p in _ = p.addTrack(kind) }
    }

    func removeTrack(_ id: UUID) {
        mutate { $0.removeTrack(id) }
    }

    func setSequence(width: Int, height: Int) {
        mutate { p in
            p.width = width
            p.height = height
            p.settingsLocked = true
        }
    }

    func setFPS(_ fps: Double) {
        mutate { p in
            p.fps = fps
            p.settingsLocked = true
        }
    }

    // MARK: Files

    private func confirmDiscard() -> Bool {
        guard isDirty, !project.clips.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your changes to “\(title)” will be lost."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Files handed to the app from outside: a project opens, anything else is imported.
    func handleOpen(_ urls: [URL]) {
        if let project = urls.first(where: { $0.pathExtension.lowercased() == "cutplay" }) {
            guard confirmDiscard() else { return }
            open(url: project)
        }
        let media = urls.filter { $0.pathExtension.lowercased() != "cutplay" }
        if !media.isEmpty { importFiles(media) }
        NSApp.activate()
    }

    func newProject() {
        guard confirmDiscard() else { return }
        load(Project(), url: nil)
        try? FileManager.default.removeItem(at: Self.recoveryURL)
        lastSession = nil
    }

    // MARK: Recent projects

    /// Projects opened or saved recently, newest first, as macOS keeps them for this app.
    @Published private(set) var recentProjects: [URL] = NSDocumentController.shared.recentDocumentURLs

    /// Adds a project to Open Recent. Test launches leave the list alone.
    private func noteRecent(_ url: URL) {
        let args = CommandLine.arguments
        guard !args.contains("--selftest"), !args.contains("--open") else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentProjects = NSDocumentController.shared.recentDocumentURLs
    }

    func openRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            importError = "“\(url.lastPathComponent)” can't be found. It may have been moved or deleted."
            return
        }
        guard confirmDiscard() else { return }
        open(url: url)
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentProjects = []
    }

    func openProject() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cutplay") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func save() {
        guard let url = fileURL else { return saveAs() }
        write(to: url)
        noteRecent(url)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cutplay") ?? .json]
        panel.nameFieldStringValue = title + ".cutplay"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
        noteRecent(url)
    }

    private func write(to url: URL) {
        commitLive()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var saved = project
            saved.stampRelativePaths(projectDir: url.deletingLastPathComponent())
            try encoder.encode(SavedDocument(project: saved)).write(to: url, options: .atomic)
            if fileURL == nil { try? FileManager.default.removeItem(at: Self.recoveryURL) }
            fileURL = url
            isDirty = false
            lastSession = url.path
        } catch {
            importError = "Couldn't save to \(url.lastPathComponent)."
        }
    }

    func load(_ p: Project, url: URL?, offerLocate: Bool = false) {
        if isPlaying { pause() }
        commitLive()
        undoStack.removeAll()
        redoStack.removeAll()
        selection = []
        playhead = 0
        project = p
        fileURL = url
        isDirty = false
        setView(scrollX: 0)
        centerRows()
        setNeedsRebuild()
        Task {
            let reconverted = await media.restore(p.assets)
            for i in self.project.assets.indices {
                if let path = reconverted[self.project.assets[i].id] { self.project.assets[i].playablePath = path }
            }
            self.objectWillChange.send()
            self.setNeedsRebuild()
            if offerLocate { self.offerToLocateMissing() }
        }
    }

    // MARK: Missing media

    /// Library items whose file can't be found.
    var missingAssets: [MediaAsset] {
        project.assets.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Points a library item at a new file, then looks in that file's folder for any other missing
    /// items by file name. Returns false when the chosen file can't stand in for the item.
    @discardableResult
    func relink(_ id: UUID, to url: URL) async -> Bool {
        guard let old = project.assets.first(where: { $0.id == id }),
              let fresh = await media.importFile(url, replacing: old),
              let i = project.assets.firstIndex(where: { $0.id == id }) else { return false }
        commitLive()
        project.assets[i] = fresh
        let folder = url.deletingLastPathComponent()
        for other in missingAssets where other.id != id {
            let candidate = folder.appendingPathComponent(URL(fileURLWithPath: other.path).lastPathComponent)
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let found = await media.importFile(candidate, replacing: other),
                  let j = project.assets.firstIndex(where: { $0.id == other.id }) else { continue }
            project.assets[j] = found
        }
        // Undo snapshots still hold the old paths, so they can't be kept.
        undoStack.removeAll()
        redoStack.removeAll()
        didChange()
        return true
    }

    /// Asks where a missing item's file is. With `thenOthers`, keeps asking for whatever is still
    /// missing afterwards until everything is found or the panel is cancelled.
    func locate(_ id: UUID, thenOthers: Bool = false) {
        guard let asset = project.assets.first(where: { $0.id == id }) else { return }
        let original = URL(fileURLWithPath: asset.path)
        let panel = NSOpenPanel()
        panel.message = "Locate “\(original.lastPathComponent)”"
        panel.prompt = "Locate"
        panel.allowedContentTypes = Self.importTypes
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = original.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await relink(id, to: url) {
                if thenOthers, let next = missingAssets.first { locate(next.id, thenOthers: true) }
            } else {
                importError = "“\(url.lastPathComponent)” can't be used in place of “\(original.lastPathComponent)”."
            }
        }
    }

    private func offerToLocateMissing() {
        let missing = missingAssets
        guard let first = missing.first else { return }
        let names = missing.prefix(6).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        let alert = NSAlert()
        alert.messageText = missing.count == 1 ? "1 media file is missing" : "\(missing.count) media files are missing"
        alert.informativeText = names.joined(separator: "\n") + (missing.count > names.count ? "\n…" : "")
            + "\n\nLocate one and any others in the same folder are found too."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { locate(first.id, thenOthers: true) }
    }
}
