import Foundation
import CoreGraphics

/// A library item shown in the main viewer while its thumbnail is hover-scrubbed. Kept apart from the
/// editor model so the frequent updates only redraw the viewer.
@MainActor
final class SourcePreviewState: ObservableObject {
    struct Current {
        let asset: MediaAsset
        var time: Double
        var image: CGImage?
        /// Said after the name: "In" or "Out" while a clip's edge is being trimmed.
        var note: String? = nil
    }

    @Published private(set) var current: Current?

    /// `quick` is a frame already at hand (made ahead, smaller) to show at once; the exact full-size
    /// frame replaces it when it's decoded, unless the mouse has moved on by then.
    func show(_ asset: MediaAsset, at time: Double, media: MediaStore, quick: CGImage? = nil, note: String? = nil) {
        if current?.asset.id != asset.id {
            current = Current(asset: asset, time: time, image: quick, note: note)
        } else {
            current?.time = time
            current?.note = note
            if let quick { current?.image = quick }
        }
        media.viewerFrame(asset: asset.id, time: time) { [weak self] img in
            guard let self, self.current?.asset.id == asset.id, self.current?.time == time else { return }
            self.current?.image = img
        }
    }

    /// Shows a frame that has already been fetched.
    func show(_ asset: MediaAsset, at time: Double, image: CGImage) {
        current = Current(asset: asset, time: time, image: image)
    }

    func clear() {
        if current != nil { current = nil }
    }
}
