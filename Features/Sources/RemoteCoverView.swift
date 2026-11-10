import SwiftUI
import UIKit

/// Covers from sources, in memory only. Downsampled, so 200 covers use little memory.
nonisolated final class RemoteImageCache: @unchecked Sendable {
    static let shared = RemoteImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func set(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }

    /// Loads a cover with the headers that the source asks for.
    func load(_ url: String, sourceID: String, manager: SourceManager, maxPixelSize: CGFloat) async -> UIImage? {
        let key = "\(sourceID)|\(url)|\(Int(maxPixelSize))"
        if let cached = image(for: key) { return cached }
        guard let runner = try? await manager.runner(for: sourceID),
              let request = try? await runner.imageRequest(for: url, context: nil),
              let (data, _) = try? await URLSession.shared.data(for: request)
        else { return nil }
        let image = await Task.detached(priority: .utility) {
            ImageDownsampler.downsample(data, maxPixelSize: maxPixelSize)
        }.value
        if let image { set(image, for: key) }
        return image
    }
}

/// A 2:3 cover from a source, styled like CoverView.
struct RemoteCoverView: View {
    let title: String
    let url: String?
    let sourceID: String
    var cornerRadius: CGFloat = Theme.Radius.cover
    var badge: String?

    @Environment(SourceManager.self) private var manager
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        } else {
                            PlaceholderCover(title: title)
                        }
                    }
                    .task(id: url) {
                        guard let url else { return }
                        let pixels = max(max(geo.size.width, geo.size.height) * displayScale, 300)
                        image = await RemoteImageCache.shared.load(url, sourceID: sourceID, manager: manager,
                                                                   maxPixelSize: pixels)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let badge { CoverBadge(text: badge).padding(6) }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}
