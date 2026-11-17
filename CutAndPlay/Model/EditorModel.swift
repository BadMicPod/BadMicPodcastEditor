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
    @Published private(set) var project = Project()
    @Published var selection: Set<UUID> = []
    @Published var tool: Tool = .move
    @Published var snapping = true
    @Published private(set) var isPlaying = false
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published var showExport = false
    @Published private(set) var importCount = 0
    @Published var importError: String?

    let view = TimelineViewState()
    let clock = Clock()
    let media = MediaStore()
    let engine = PlaybackEngine()
    let exporter = Exporter()

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
            self.isPlaying = false
            self.playhead = self.project.duration
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
            }
        }
    }

    func open(url: URL) {
        do {
            let doc = try JSONDecoder().decode(SavedDocument.self, from: Data(contentsOf: url))
            load(doc.project, url: url)
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
        if isPlaying && engine.isEmpty { isPlaying = false }
    }

    // MARK: Transport

    func tick() {
        if isPlaying { playhead = min(engine.currentTime, max(engine.duration, 0)) }
        clock.update(time: playhead, fps: project.fps)
        for handler in tickHandlers { handler() }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
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
        let ids = project.linked(selection)
        mutate { $0.remove(ids: ids, ripple: ripple) }
    }

    func splitAtPlayhead() {
        let t = playhead
        let under = project.clips.filter { $0.start < t && $0.end > t }
        let selected = under.filter { selection.contains($0.id) }
        let targets = project.linked(Set((selected.isEmpty ? under : selected).map(\.id)))
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

    func setSpeed(_ speed: Double) {
        let ids = project.linked(selection)
        mutate { $0.setSpeed(ids: ids, speed: speed) }
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

    func newProject() {
        guard confirmDiscard() else { return }
        load(Project(), url: nil)
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
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cutplay") ?? .json]
        panel.nameFieldStringValue = title + ".cutplay"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        commitLive()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(SavedDocument(project: project)).write(to: url, options: .atomic)
            fileURL = url
            isDirty = false
        } catch {
            importError = "Couldn't save to \(url.lastPathComponent)."
        }
    }

    func load(_ p: Project, url: URL?) {
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
            await media.restore(p.assets)
            self.objectWillChange.send()
            self.setNeedsRebuild()
        }
    }
}
