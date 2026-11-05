import SwiftUI
import UIKit

/// Displays an image from `ImageStore`, downsampled to `maxPixelSize` and decoded off the main thread.
struct StoredImageView: View {
    let fileName: String
    let maxPixelSize: Int
    var contentMode: ContentMode = .fill
    /// Plays an animated file's frames instead of its first frame.
    var animates = false

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var animationFrame: UIImage?
    /// Changed to try a failed load again.
    @State private var loadAttempt = 0
    @Environment(\.scenePhase) private var scenePhase

    /// Smaller size that's usually already cached by the library grid; shown while loading.
    static let thumbnailPixelSize = 480

    init(fileName: String, maxPixelSize: Int, contentMode: ContentMode = .fill, animates: Bool = false) {
        self.fileName = fileName
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.animates = animates
        let loader = ImageLoader.shared
        _image = State(initialValue: loader.cachedImage(fileName: fileName, maxPixelSize: maxPixelSize)
            ?? loader.cachedImage(fileName: fileName, maxPixelSize: Self.thumbnailPixelSize))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: animationFrame ?? image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                // Opaque, so a transparency backdrop behind this view waits for an actual image.
                Rectangle().fill(.fill.tertiary).background(Color(.systemBackground))
                if loadFailed {
                    // The file is missing or can't be decoded.
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Image unavailable")
                }
            }
        }
        .task(id: "\(fileName)#\(maxPixelSize)#\(loadAttempt)") {
            loadFailed = false
            let loaded = await ImageLoader.shared.image(fileName: fileName, maxPixelSize: maxPixelSize)
            // A cancelled load says nothing about the file, and a newer one may be under way.
            guard !Task.isCancelled else { return }
            if let loaded {
                image = loaded
            } else {
                loadFailed = true
            }
        }
        // An SVG can't be rendered while the app is in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, loadFailed { loadAttempt += 1 }
        }
        .playsAnimation(of: ImageStore.url(for: fileName), isActive: animates, frame: $animationFrame)
    }
}

/// A subtle checkerboard shown behind transparent images.
struct Checkerboard: View {
    var squareSize: CGFloat = 10
    /// Uses `VectorBackdrop`'s colours in both light and dark mode.
    var isVectorBackdrop = false

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * squareSize, y: CGFloat(row) * squareSize,
                                      width: squareSize, height: squareSize)
                    context.fill(Path(rect), with: isVectorBackdrop ? .color(Color(VectorBackdrop.squareColor)) : .style(.fill.tertiary))
                }
            }
        }
        .background(isVectorBackdrop ? AnyShapeStyle(Color(VectorBackdrop.baseColor)) : AnyShapeStyle(.fill.quaternary))
    }
}

/// What's shown behind an SVG's unpainted canvas. The same in light and dark mode, unlike
/// `Checkerboard`'s usual colours: SVG shapes are black unless they say otherwise and most documents
/// expect a white page, so dark squares would hide them. White alone would hide white or cream
/// artwork, which shows up against the grey squares here.
enum VectorBackdrop {
    static let baseColor = UIColor.white
    static let squareColor = UIColor(white: 0.8, alpha: 1)

    /// The same pattern for UIKit views.
    static func patternColor(squareSize: CGFloat = 10) -> UIColor {
        let size = CGSize(width: squareSize * 2, height: squareSize * 2)
        return UIColor(patternImage: UIGraphicsImageRenderer(size: size).image { context in
            baseColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            squareColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: squareSize, height: squareSize))
            context.fill(CGRect(x: squareSize, y: squareSize, width: squareSize, height: squareSize))
        })
    }
}

extension View {
    /// Puts the right checkerboard behind a library image that may be transparent.
    func transparencyBackdrop(for image: GeneratedImage, squareSize: CGFloat = 10) -> some View {
        background {
            if image.format.isVector {
                Checkerboard(squareSize: squareSize, isVectorBackdrop: true)
            } else if image.isTransparent {
                Checkerboard(squareSize: squareSize)
            }
        }
    }
}
