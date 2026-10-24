import SwiftUI
import UIKit
import ImageIO

/// Plays an animated GIF, APNG or WebP page in an image view.
///
/// ImageIO decodes one frame at a time, when it is due, and calls back on the
/// main queue. Only the frame on screen is in memory, so a long animation costs
/// about as much as one still page. With Reduce Motion on, the page stays still.
final class AnimatedImagePlayer {
    /// Shared with the ImageIO block, which stops itself once this is set.
    private final class Session {
        var isStopped = false
    }

    private var session: Session?
    private var url: URL?

    var isPlaying: Bool { session != nil }

    func play(_ url: URL, in imageView: UIImageView) {
        if isPlaying, self.url == url { return }
        stop()
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        let session = Session()
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak imageView] _, frame, stop in
            guard !session.isStopped, let imageView else {
                stop.pointee = true
                return
            }
            imageView.image = UIImage(cgImage: frame)
        }
        guard status == noErr else { return }
        self.session = session
        self.url = url
    }

    func stop() {
        session?.isStopped = true
        session = nil
        url = nil
    }
}

/// An animated page in Vertical Scroll mode. It plays while the row exists
/// (LazyVStack removes rows that scroll far off screen, which stops it).
struct AnimatedPageView: UIViewRepresentable {
    let url: URL
    /// The downsampled first frame, shown until the animation starts.
    let poster: UIImage?

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if !context.coordinator.player.isPlaying { view.image = poster }
        context.coordinator.player.play(url, in: view)
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.player.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let player = AnimatedImagePlayer()
    }
}
