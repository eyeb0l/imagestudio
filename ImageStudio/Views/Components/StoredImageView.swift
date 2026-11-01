import SwiftUI
import UIKit

/// Displays an image from `ImageStore`, downsampled to `maxPixelSize` and decoded off the main thread.
struct StoredImageView: View {
    let fileName: String
    let maxPixelSize: Int
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var loadFailed = false

    /// Smaller size that's usually already cached by the library grid; shown while loading.
    static let thumbnailPixelSize = 480

    init(fileName: String, maxPixelSize: Int, contentMode: ContentMode = .fill) {
        self.fileName = fileName
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        let loader = ImageLoader.shared
        _image = State(initialValue: loader.cachedImage(fileName: fileName, maxPixelSize: maxPixelSize)
            ?? loader.cachedImage(fileName: fileName, maxPixelSize: Self.thumbnailPixelSize))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.fill.tertiary)
                if loadFailed {
                    // The file is missing or can't be decoded.
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Image unavailable")
                }
            }
        }
        .task(id: "\(fileName)#\(maxPixelSize)") {
            loadFailed = false
            if let loaded = await ImageLoader.shared.image(fileName: fileName, maxPixelSize: maxPixelSize) {
                image = loaded
            } else {
                loadFailed = true
            }
        }
    }
}

/// A subtle checkerboard shown behind transparent images.
struct Checkerboard: View {
    var squareSize: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * squareSize, y: CGFloat(row) * squareSize,
                                      width: squareSize, height: squareSize)
                    context.fill(Path(rect), with: .style(.fill.tertiary))
                }
            }
        }
        .background(.fill.quaternary)
    }
}
