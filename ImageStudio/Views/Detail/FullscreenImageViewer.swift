import SwiftUI
import UIKit

/// An image file to show full screen (a library image or a reference), and any markup to show on it.
struct FullscreenItem: Identifiable {
    let url: URL
    var overlayURL: URL?
    var id: String { "\(url.path(percentEncoded: false))#\(overlayURL?.path(percentEncoded: false) ?? "")" }
}

/// Full-screen, pinch- and double-tap-zoomable view of an image.
struct FullscreenImageViewer: View {
    let url: URL
    /// A same-sized transparent layer shown on top of the image, as part of it.
    var overlayURL: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var loadAttempt = 0
    @State private var uiImage: UIImage?
    @State private var vector: VectorSource?
    @State private var loadFailed = false
    @State private var animationFrame: UIImage?

    init(url: URL, overlayURL: URL? = nil) {
        self.url = url
        self.overlayURL = overlayURL
        // Shown while the full-size image loads, which for an SVG can mean starting a web view.
        // Not with an overlay, as the image alone would suggest it has none.
        guard overlayURL == nil else { return }
        let loader = ImageLoader.shared
        _uiImage = State(initialValue: loader.cachedImage(at: url, maxPixelSize: Self.detailPixelSize)
            ?? loader.cachedImage(at: url, maxPixelSize: StoredImageView.thumbnailPixelSize))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let uiImage {
                ZoomableImage(image: animationFrame ?? uiImage, showsVectorBackdrop: SVGDocument.isSVG(url), vector: vector)
                    .ignoresSafeArea()
            } else if loadFailed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Image unavailable")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .task(id: loadAttempt) {
            var image = await ImageLoader.shared.image(at: url, maxPixelSize: Self.basePixelSize)
            if let overlayURL, let base = image {
                image = await MarkupCompositor.composite(base, overlayURL: overlayURL)
            }
            if SVGDocument.isSVG(url), image != nil { vector = await VectorSource.load(url) }
            // A cancelled load says nothing about the file, and a newer one may be under way.
            guard !Task.isCancelled else { return }
            if let image { uiImage = image }
            loadFailed = image == nil
        }
        // An SVG can't be rendered while the app is in the background. With a smaller cached copy
        // on screen this still matters, as that's all there'd be to zoom into.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, loadFailed { loadAttempt += 1 }
        }
        .playsAnimation(of: url, frame: $animationFrame)
    }

    /// What every format is first decoded to. Zooming into an SVG beyond this renders more detail.
    fileprivate static let basePixelSize = 4096
    /// What the detail view shows, so it's usually in memory already.
    static let detailPixelSize = 2048
}

/// An SVG's contents, kept while it's on screen to render more detail as it's zoomed.
private struct VectorSource: Sendable {
    let data: Data
    let document: SVGDocument

    @concurrent
    static func load(_ url: URL) async -> VectorSource? {
        guard let data = try? Data(contentsOf: url), let document = SVGDocument(data: data) else { return nil }
        return VectorSource(data: data, document: document)
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let showsVectorBackdrop: Bool
    var vector: VectorSource?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let content = ZoomableContentView(image: image)
        content.frame = scrollView.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(content)
        context.coordinator.content = content

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.content?.image = image
        context.coordinator.content?.showsVectorBackdrop = showsVectorBackdrop
        context.coordinator.vector = vector
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var content: ZoomableContentView?
        var vector: VectorSource?
        private var detailTask: Task<Void, Never>?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = recognizer.location(in: content)
                let scale: CGFloat = 3
                let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                  width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }

        // MARK: Vector detail

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            updateVectorDetail(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { updateVectorDetail(in: scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateVectorDetail(in: scrollView)
        }

        /// A bitmap of the whole document can only be so large, so past the zoom where it runs out
        /// of pixels, renders just the part on screen at the screen's resolution and lays it on top.
        private func updateVectorDetail(in scrollView: UIScrollView) {
            detailTask?.cancel()
            guard let vector, let content else { return }
            let fitted = content.fittedImageRect
            let scale = scrollView.traitCollection.displayScale * scrollView.zoomScale
            let documentPixels = CGSize(width: fitted.width * scale, height: fitted.height * scale)
            let visible = content.convert(scrollView.bounds, from: scrollView).intersection(fitted)
            guard !visible.isEmpty, fitted.width > 0, fitted.height > 0,
                  max(documentPixels.width, documentPixels.height) > CGFloat(FullscreenImageViewer.basePixelSize) else {
                content.setVectorDetail(nil, frame: .zero)
                return
            }
            let region = CGRect(x: (visible.minX - fitted.minX) / fitted.width,
                                y: (visible.minY - fitted.minY) / fitted.height,
                                width: visible.width / fitted.width,
                                height: visible.height / fitted.height)
            detailTask = Task { [weak content] in
                // Panning sends many of these. Only the place it stops at matters.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                let plan = SVGRenderPlan(document: vector.document, documentPixels: documentPixels, region: region)
                guard let detail = try? await SVGRasterizer.shared.render(vector.data, plan: plan),
                      !Task.isCancelled else { return }
                content?.setVectorDetail(detail, frame: visible)
            }
        }
    }
}

/// The view that zooms: the image, with an SVG's backdrop behind it and any sharper detail above.
private final class ZoomableContentView: UIView {
    private let imageView = UIImageView()
    /// Behind the image's own area only, so the letterbox stays black.
    private let backdrop = UIView()
    /// Clips the detail and its own copy of the backdrop. Vectors can be transparent, so the blurrier
    /// base image has to be covered up for the detail not to show it through its gaps.
    private let detailContainer = UIView()
    private let detailBackdrop = UIView()
    private let detailImageView = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    var showsVectorBackdrop = false {
        didSet {
            guard showsVectorBackdrop != oldValue else { return }
            let pattern = showsVectorBackdrop ? VectorBackdrop.patternColor() : nil
            backdrop.backgroundColor = pattern
            detailBackdrop.backgroundColor = pattern
            setNeedsLayout()
        }
    }

    /// Where the image appears, in this view's coordinates, as it's scaled to fit.
    var fittedImageRect: CGRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    init(image: UIImage) {
        super.init(frame: .zero)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        detailContainer.clipsToBounds = true
        detailContainer.isHidden = true
        detailContainer.addSubview(detailBackdrop)
        detailContainer.addSubview(detailImageView)
        addSubview(backdrop)
        addSubview(imageView)
        addSubview(detailContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        guard showsVectorBackdrop else { return }
        if backdrop.frame != fittedImageRect {
            backdrop.frame = fittedImageRect
            // It was placed for the old layout, e.g. before a rotation.
            setVectorDetail(nil, frame: .zero)
        }
    }

    func setVectorDetail(_ detail: UIImage?, frame: CGRect) {
        detailContainer.isHidden = detail == nil
        detailImageView.image = detail
        detailContainer.frame = frame
        detailImageView.frame = detailContainer.bounds
        // Keeps its squares lined up with the ones around it.
        detailBackdrop.frame = backdrop.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
}
