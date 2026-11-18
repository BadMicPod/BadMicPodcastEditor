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
    }

    @Published private(set) var current: Current?

    func show(_ asset: MediaAsset, at time: Double, media: MediaStore) {
        if current?.asset.id != asset.id {
            current = Current(asset: asset, time: time, image: nil)
        } else {
            current?.time = time
        }
        media.viewerFrame(asset: asset.id, time: time) { [weak self] img in
            guard let self, self.current?.asset.id == asset.id else { return }
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
