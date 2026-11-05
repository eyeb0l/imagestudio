import SwiftUI
import UIKit

/// A small rounded square showing a reference image from `ReferenceStore`, with its markup if given.
struct ReferenceThumbnail: View {
    let fileName: String
    var size: CGFloat = 56
    var markupFileName: String?

    @State private var image: UIImage?
    @State private var markupImage: UIImage?
    @State private var loadFailed = false

    private var url: URL { ReferenceStore.url(for: fileName) }
    private static let pixelSize = 300

    init(fileName: String, size: CGFloat = 56, markupFileName: String? = nil) {
        self.fileName = fileName
        self.size = size
        self.markupFileName = markupFileName
        _image = State(initialValue: ImageLoader.shared.cachedImage(at: ReferenceStore.url(for: fileName),
                                                                     maxPixelSize: Self.pixelSize))
    }

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    if markupFileName == nil {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // Whole rather than filling the square, so no strokes are cropped away.
                        Rectangle().fill(.fill.tertiary)
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                        if let markupImage {
                            Image(uiImage: markupImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                } else {
                    Rectangle().fill(.fill.tertiary)
                    if loadFailed {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: size * 0.3, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: size * 0.2))
            .task(id: fileName) {
                if let loaded = await ImageLoader.shared.image(at: url, maxPixelSize: Self.pixelSize) {
                    image = loaded
                } else {
                    loadFailed = true
                }
            }
            .task(id: markupFileName) {
                guard let markupFileName else { return }
                markupImage = await ImageLoader.shared.image(at: ReferenceStore.url(for: markupFileName), maxPixelSize: Self.pixelSize)
            }
            .accessibilityLabel(loadFailed ? "Reference image unavailable"
                                : markupFileName != nil ? "Reference image with markup" : "Reference image")
    }
}
