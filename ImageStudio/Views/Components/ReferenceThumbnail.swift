import SwiftUI
import UIKit

/// A small rounded square showing a reference image from `ReferenceStore`.
struct ReferenceThumbnail: View {
    let fileName: String
    var size: CGFloat = 56

    @State private var image: UIImage?
    @State private var loadFailed = false

    private var url: URL { ReferenceStore.url(for: fileName) }
    private static let pixelSize = 300

    init(fileName: String, size: CGFloat = 56) {
        self.fileName = fileName
        self.size = size
        _image = State(initialValue: ImageLoader.shared.cachedImage(at: ReferenceStore.url(for: fileName),
                                                                     maxPixelSize: Self.pixelSize))
    }

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
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
            .accessibilityLabel(loadFailed ? "Reference image unavailable" : "Reference image")
    }
}
