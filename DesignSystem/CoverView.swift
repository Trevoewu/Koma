import SwiftUI

/// A 2:3 manga cover with rounded corners and an optional badge.
/// If there is no image yet, it draws a placeholder cover from the title.
struct CoverView: View {
    let title: String
    var imageURL: URL?
    var cornerRadius: CGFloat = Theme.Radius.cover
    var badge: String?

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let imageURL {
                    DownsampledImage(url: imageURL) { PlaceholderCover(title: title) }
                } else {
                    PlaceholderCover(title: title)
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

/// Loads an image file at the size of the view (see ImageDownsampler).
struct DownsampledImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    placeholder()
                }
            }
            .task(id: url) {
                let maxPixels = max(geo.size.width, geo.size.height) * displayScale
                image = await ImageDownsampler.load(url, maxPixelSize: max(maxPixels, 300))
            }
        }
    }
}

/// Generated cover art: a color block, a circle, a band and the title.
/// The same title always gets the same colors.
struct PlaceholderCover: View {
    let title: String

    var body: some View {
        let palette = CoverPalette.for(title)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                palette.base
                Circle()
                    .fill(palette.accent)
                    .frame(width: w * 0.7, height: w * 0.7)
                    .position(x: w * 0.83, y: w * 0.17)
                Rectangle()
                    .fill(palette.band)
                    .frame(width: w * 1.2, height: h * 0.18)
                    .rotationEffect(.degrees(-12))
                    .position(x: w / 2, y: h * 0.63)
                Text(title.uppercased())
                    .font(.system(size: max(9, w * 0.11), weight: .heavy))
                    .foregroundStyle(palette.ink)
                    .lineLimit(3)
                    .padding(w * 0.08)
            }
        }
    }
}

struct CoverPalette {
    let base: Color, accent: Color, band: Color, ink: Color

    static let all: [CoverPalette] = [
        .init(base: Color(hex: 0x1F3A5F), accent: Color(hex: 0xE9B872), band: Color(hex: 0x2E5A88), ink: Color(hex: 0xF4E9D8)),
        .init(base: Color(hex: 0xC8553D), accent: Color(hex: 0xF6C28B), band: Color(hex: 0x9E3B2A), ink: Color(hex: 0xFFF4E6)),
        .init(base: Color(hex: 0xE8C547), accent: Color(hex: 0xFFFFFF), band: Color(hex: 0xD9A92F), ink: Color(hex: 0x1B1B1B)),
        .init(base: Color(hex: 0x2E2E2E), accent: Color(hex: 0xF2D16B), band: Color(hex: 0x444444), ink: Color(hex: 0xF2D16B)),
        .init(base: Color(hex: 0x4A6D5A), accent: Color(hex: 0xC9D8B6), band: Color(hex: 0x36513F), ink: Color(hex: 0xF1F5EE)),
        .init(base: Color(hex: 0x111827), accent: Color(hex: 0x7DD3FC), band: Color(hex: 0x1F2A44), ink: Color(hex: 0x7DD3FC)),
        .init(base: Color(hex: 0x6B4E71), accent: Color(hex: 0xE8B4BC), band: Color(hex: 0x553C5A), ink: Color(hex: 0xF6EEF7)),
        .init(base: Color(hex: 0x3D7EA6), accent: Color(hex: 0xCDEAF5), band: Color(hex: 0x2F6587), ink: Color(hex: 0xFFFFFF)),
        .init(base: Color(hex: 0x8C5A3C), accent: Color(hex: 0xF0B67F), band: Color(hex: 0x6E432B), ink: Color(hex: 0xFBEFE3))
    ]

    /// Stable choice per title. (String.hashValue changes on every launch, so we use djb2.)
    static func `for`(_ title: String) -> CoverPalette {
        var hash: UInt64 = 5381
        for byte in title.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return all[Int(hash % UInt64(all.count))]
    }
}

#Preview {
    HStack(spacing: 12) {
        CoverView(title: "Tidewater Saints", badge: "8 vols")
        CoverView(title: "Night Bus 404", badge: "NEW")
        CoverView(title: "夏日静电")
    }
    .padding()
    .background(ScreenBackground())
}
