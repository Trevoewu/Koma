import SwiftUI
import UIKit

/// One page, or two pages side by side, with pinch and double-tap zoom.
///
/// UIKit, because SwiftUI has no zooming scroll view. At zoom 1 the content is
/// exactly the screen, so horizontal swipes go to the outer paging scroll view.
/// After a zoom it loads a sharper image for the new scale, and drops it on zoom out.
struct ZoomablePageView: UIViewRepresentable {
    /// In page order. nil = not loaded yet.
    var images: [UIImage?]
    /// Width / height of each page.
    var aspectRatios: [CGFloat]
    var urls: [URL]
    /// Per page: play it as an animation while this group is on screen.
    var animated: [Bool]
    /// Right to left: the lower page goes on the right.
    var rightToLeft: Bool
    /// False for pages next to the current one: they reset their zoom.
    var isActive: Bool
    var onTap: (ReaderModel.TapZone) -> Void

    func makeUIView(context: Context) -> PageZoomView { PageZoomView() }

    func updateUIView(_ view: PageZoomView, context: Context) {
        view.onTap = onTap
        view.configure(images: images, aspectRatios: aspectRatios, urls: urls, rightToLeft: rightToLeft)
        if !isActive { view.resetZoom() }
        // Only the group on screen plays. Pages next to it show their first frame.
        view.updateAnimations(animated.map { $0 && isActive })
    }

    static func dismantleUIView(_ view: PageZoomView, coordinator: ()) {
        view.updateAnimations([])
    }
}

final class PageZoomView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onTap: ((ReaderModel.TapZone) -> Void)?

    private let container = UIView()
    private var imageViews: [UIImageView] = []
    private var players: [AnimatedImagePlayer] = []
    private var baseImages: [UIImage?] = []
    private var aspectRatios: [CGFloat] = []
    private var urls: [URL] = []
    private var rightToLeft = false
    private var showsSharpImages = false
    private var sharpTask: Task<Void, Never>?

    private lazy var doubleTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        gesture.numberOfTapsRequired = 2
        gesture.delegate = self
        return gesture
    }()

    private lazy var singleTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        gesture.require(toFail: doubleTap)
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        // The SwiftUI parent may be right-to-left. Page order is set by hand below.
        semanticContentAttribute = .forceLeftToRight
        addSubview(container)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(images: [UIImage?], aspectRatios: [CGFloat], urls: [URL], rightToLeft: Bool) {
        if imageViews.count != images.count {
            players.forEach { $0.stop() }
            players = images.map { _ in AnimatedImagePlayer() }
            imageViews.forEach { $0.removeFromSuperview() }
            imageViews = images.map { _ in
                let view = UIImageView()
                view.contentMode = .scaleAspectFit
                view.backgroundColor = UIColor(white: 0.06, alpha: 1)
                container.addSubview(view)
                return view
            }
            resetZoom()
        }
        baseImages = images
        self.urls = urls
        if !showsSharpImages {
            for (index, (view, image)) in zip(imageViews, images).enumerated()
            where view.image !== image && !players[index].isPlaying {
                view.image = image
                view.backgroundColor = image == nil ? UIColor(white: 0.06, alpha: 1) : .clear
            }
        }
        if aspectRatios != self.aspectRatios || rightToLeft != self.rightToLeft {
            self.aspectRatios = aspectRatios
            self.rightToLeft = rightToLeft
            setNeedsLayout()
        }
    }

    /// Starts or stops the animation of each page. A stopped page shows its still image again.
    func updateAnimations(_ playing: [Bool]) {
        for (index, player) in players.enumerated() {
            let shouldPlay = playing.indices.contains(index) && playing[index] && urls.indices.contains(index)
            if shouldPlay {
                imageViews[index].backgroundColor = .clear
                player.play(urls[index], in: imageViews[index])
            } else if player.isPlaying {
                player.stop()
                imageViews[index].image = baseImages.indices.contains(index) ? baseImages[index] : nil
            }
        }
    }

    func resetZoom() {
        if zoomScale != 1 { setZoomScale(1, animated: false) }
        dropSharpImages()
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, abs(zoomScale - 1) < 0.001 else { return }

        let ratios = aspectRatios.count == imageViews.count ? aspectRatios : imageViews.map { _ in 2.0 / 3.0 }
        let total = max(ratios.reduce(0, +), 0.1)
        let height = min(bounds.height, bounds.width / total)
        let size = CGSize(width: height * total, height: height)
        container.frame = CGRect(origin: .zero, size: size)
        contentSize = size

        var x: CGFloat = 0
        let order = rightToLeft ? Array(imageViews.indices.reversed()) : Array(imageViews.indices)
        for index in order {
            let width = height * ratios[index]
            imageViews[index].frame = CGRect(x: x, y: 0, width: width, height: height)
            x += width
        }
        centerContent()
    }

    /// Keeps a page that is smaller than the screen in the middle.
    private func centerContent() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale > 1.3 { loadSharpImages(for: scale) } else { dropSharpImages() }
    }

    private func loadSharpImages(for scale: CGFloat) {
        sharpTask?.cancel()
        let displayScale = traitCollection.displayScale
        let targets = zip(urls, imageViews).enumerated().map { index, pair in
            let (url, view) = pair
            return players[index].isPlaying ? nil : (url, min(max(view.bounds.width, view.bounds.height) * scale * displayScale, 4096))
        }
        sharpTask = Task { [weak self] in
            var images: [UIImage?] = []
            for target in targets {
                guard let (url, pixels) = target else { images.append(nil); continue }
                images.append(await ImageDownsampler.load(url, maxPixelSize: pixels))
            }
            guard let self, !Task.isCancelled, self.zoomScale > 1.01 else { return }
            self.showsSharpImages = true
            for (view, image) in zip(self.imageViews, images) where image != nil {
                view.image = image
            }
        }
    }

    private func dropSharpImages() {
        sharpTask?.cancel()
        guard showsSharpImages else { return }
        showsSharpImages = false
        for (index, (view, image)) in zip(imageViews, baseImages).enumerated() where !players[index].isPlaying {
            view.image = image
        }
    }

    // MARK: Taps

    /// Double tap zooms only in the center zone (or anywhere to zoom back out),
    /// so taps on the sides turn the page at once, without waiting for a second tap.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === doubleTap else { return true }
        return zoomScale > 1.01 || zone(at: touch.location(in: self)) == .center
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        onTap?(zone(at: gesture.location(in: self)))
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: container)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }

    /// Left 30% / center 40% / right 30% of the visible area.
    private func zone(at point: CGPoint) -> ReaderModel.TapZone {
        let fraction = (point.x - bounds.minX) / max(bounds.width, 1)
        if fraction < 0.3 { return .left }
        if fraction > 0.7 { return .right }
        return .center
    }
}
