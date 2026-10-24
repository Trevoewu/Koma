import UIKit
import ImageIO

/// Decodes an image at the size the screen needs, not at full size.
///
/// A manga page can be 2000 × 3000 px. Decoded at full size, that is about 24 MB
/// of memory per page. Covers in a grid and pages in the reader must always go
/// through this, or the app runs out of memory on large libraries.
enum ImageDownsampler {
    /// Loads off the main thread.
    nonisolated static func load(_ url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            downsample(url, maxPixelSize: maxPixelSize)
        }.value
    }

    nonisolated static func downsample(_ url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 64)
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
