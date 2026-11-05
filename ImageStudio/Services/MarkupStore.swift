import Foundation
import ImageIO
import PencilKit
import UIKit
import UniformTypeIdentifiers

/// How the canvas lines up with a reference image.
///
/// The drawing has its own coordinates, the same for every device and orientation: the image's
/// shape, with its long edge `canvasLongEdge` units long. PencilKit only accepts a narrow range of
/// line widths (0.5 to 4 for monoline ink), so this is what makes a line a sensible size on the
/// image whatever its resolution. On screen the canvas is zoomed to cover exactly the part of the
/// view the image fills, so the letterboxing around it plays no part in the drawing.
nonisolated struct MarkupGeometry: Equatable, Sendable {
    static let canvasLongEdge: CGFloat = 256

    let pixelWidth: Int
    let pixelHeight: Int

    init?(pixelWidth: Int, pixelHeight: Int) {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var pixelCount: Int { pixelWidth * pixelHeight }

    var pixelsPerCanvasUnit: CGFloat {
        CGFloat(max(pixelWidth, pixelHeight)) / Self.canvasLongEdge
    }

    var canvasSize: CGSize {
        CGSize(width: CGFloat(pixelWidth) / pixelsPerCanvasUnit, height: CGFloat(pixelHeight) / pixelsPerCanvasUnit)
    }

    /// Where the image appears when it's aspect-fitted to `bounds`, centred.
    func fittedRect(in bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / CGFloat(pixelWidth), bounds.height / CGFloat(pixelHeight))
        let size = CGSize(width: CGFloat(pixelWidth) * scale, height: CGFloat(pixelHeight) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The canvas's zoom when it covers `fitted`.
    func zoomScale(for fitted: CGRect) -> CGFloat {
        fitted.width / canvasSize.width
    }

    /// A point in a view whose bounds the image is fitted to, in canvas coordinates.
    func canvasPoint(forViewPoint point: CGPoint, in bounds: CGRect) -> CGPoint {
        let fitted = fittedRect(in: bounds)
        let zoom = zoomScale(for: fitted)
        return CGPoint(x: (point.x - fitted.minX) / zoom, y: (point.y - fitted.minY) / zoom)
    }

    func pixelPoint(forCanvasPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * pixelsPerCanvasUnit, y: point.y * pixelsPerCanvasUnit)
    }
}

/// Turns a drawing into the annotation layer sent as `markup`.
nonisolated enum MarkupExporter {
    /// A PNG with an alpha channel at exactly the geometry's pixel size, holding the strokes and
    /// nothing else. `nil` if that would be nothing at all: an empty drawing means no markup.
    @concurrent
    static func overlayPNG(from drawing: PKDrawing, geometry: MarkupGeometry) async throws -> Data? {
        try renderOverlay(from: drawing, geometry: geometry)
    }

    static func renderOverlay(from drawing: PKDrawing, geometry: MarkupGeometry) throws -> Data? {
        guard geometry.pixelCount <= MarkupStore.maxPixels else { throw MarkupStore.MarkupError.tooManyPixels }
        guard !drawing.strokes.isEmpty else { return nil }

        // Scaled to the pixel grid and then rendered at scale 1, so a fractional canvas size can't
        // round its way to a different size of image.
        let pixels = CGRect(x: 0, y: 0, width: geometry.pixelWidth, height: geometry.pixelHeight)
        let scale = geometry.pixelsPerCanvasUnit
        let scaled = drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
        var rendered: UIImage?
        // Ink colours otherwise adapt to dark mode, and the file should hold what was picked.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = scaled.image(from: pixels, scale: 1)
        }

        guard let strokes = rendered?.cgImage,
              let context = CGContext(data: nil, width: geometry.pixelWidth, height: geometry.pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixelData = context.data else { throw MarkupStore.MarkupError.renderFailed }
        // Anchored to the top left, the origin of what was rendered. Core Graphics counts up from the bottom.
        context.draw(strokes, in: CGRect(x: 0, y: geometry.pixelHeight - strokes.height,
                                         width: strokes.width, height: strokes.height))

        var hasInk = false
        var hasTransparency = false
        let row = context.bytesPerRow
        let bytes = pixelData.assumingMemoryBound(to: UInt8.self)
        scan: for y in 0..<geometry.pixelHeight {
            for x in 0..<geometry.pixelWidth {
                let alpha = bytes[y * row + x * 4 + 3]
                if alpha > 0 { hasInk = true }
                if alpha < 255 { hasTransparency = true }
                if hasInk, hasTransparency { break scan }
            }
        }
        guard hasInk else { return nil }
        guard hasTransparency else { throw MarkupStore.MarkupError.noTransparency }

        guard let image = context.makeImage() else { throw MarkupStore.MarkupError.renderFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw MarkupStore.MarkupError.renderFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MarkupStore.MarkupError.renderFailed }
        guard output.length <= MarkupStore.maxFileSize else { throw MarkupStore.MarkupError.fileTooLarge }
        return output as Data
    }
}

/// Stores markup in `ReferenceStore`'s directory, so `Studio`'s accounting of those files covers it.
///
/// One markup is two files: the overlay that's uploaded (`<id>.markup.png`) and the strokes, kept so
/// the canvas can reopen for further editing (`<id>.markup.pkdrawing`). Records hold the overlay's
/// name only and the other is worked out from it, so the two can't come apart. Each save gets a new
/// name, and as with references every owner shares files by name until the last one lets go.
nonisolated enum MarkupStore {
    /// The API's limit on the first input image and the annotation layer, each.
    static let maxPixels = 16_777_216
    /// The API's limit on the annotation file.
    static let maxFileSize = 50 * 1024 * 1024

    enum MarkupError: LocalizedError, Equatable {
        case missing
        case noReference
        case mismatchedSize
        case noAlpha
        case tooManyPixels
        case fileTooLarge
        case noTransparency
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .missing: "The markup for this generation is missing from this device."
            case .noReference: "This generation has markup but no reference image for it to apply to."
            case .mismatchedSize: "The markup doesn't match the size of the first reference image."
            case .noAlpha: "The markup file isn't a PNG with transparency."
            case .tooManyPixels: "This image is too large to mark up. The limit is \(maxPixels.formatted()) pixels."
            case .fileTooLarge: "The markup is too large to send. The limit is 50 MB."
            case .noTransparency: "The markup covers the whole image. Leave part of it clear so OpenAI can see the image."
            case .renderFailed: "The markup couldn't be saved."
            }
        }
    }

    static func drawingFileName(forOverlay overlay: String) -> String {
        "\((overlay as NSString).deletingPathExtension).pkdrawing"
    }

    /// Every file belonging to a markup. Empty for `nil`, to suit optional markup.
    static func fileNames(forOverlay overlay: String?) -> [String] {
        overlay.map { [$0, drawingFileName(forOverlay: $0)] } ?? []
    }

    /// Writes a new markup and returns its overlay's name. The overlay goes last, so an overlay
    /// that exists always has its drawing.
    static func save(overlay: Data, drawing: Data) throws -> String {
        let name = "\(UUID().uuidString).markup.png"
        let drawingName = drawingFileName(forOverlay: name)
        do {
            try drawing.write(to: ReferenceStore.url(for: drawingName), options: .atomic)
            try overlay.write(to: ReferenceStore.url(for: name), options: .atomic)
        } catch {
            ReferenceStore.delete([drawingName])
            throw error
        }
        return name
    }

    /// Copies a markup for a new owner, as `ReferenceStore.duplicate` does for references. A drawing
    /// that's gone is left gone: the overlay is what's sent, and the drawing only allows more editing.
    static func duplicate(_ overlay: String) throws -> String {
        let name = "\(UUID().uuidString).markup.png"
        try FileManager.default.copyItem(at: ReferenceStore.url(for: overlay), to: ReferenceStore.url(for: name))
        try? FileManager.default.copyItem(at: ReferenceStore.url(for: drawingFileName(forOverlay: overlay)),
                                          to: ReferenceStore.url(for: drawingFileName(forOverlay: name)))
        return name
    }

    static func delete(overlay: String?) {
        ReferenceStore.delete(fileNames(forOverlay: overlay))
    }

    /// The strokes for reopening the canvas, or `nil` if they can't be restored.
    static func loadDrawing(forOverlay overlay: String) -> PKDrawing? {
        guard let data = try? Data(contentsOf: ReferenceStore.url(for: drawingFileName(forOverlay: overlay))) else { return nil }
        return try? PKDrawing(data: data)
    }

    /// The width and height of an image file after orientation.
    static func pixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // Orientations 5 to 8 turn the image on its side.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// The `markup` part for a request, after checking it against what the API requires. Done at
    /// send time, so a problem shows as a failed generation rather than an unmarked or rejected edit.
    static func upload(overlay: String, firstReference: String) throws -> OpenAIImageClient.ReferenceUpload {
        guard ReferenceStore.fileExists(overlay) else { throw MarkupError.missing }
        let overlayURL = ReferenceStore.url(for: overlay)
        guard let size = pixelSize(at: overlayURL) else { throw MarkupError.noAlpha }
        guard let referenceSize = pixelSize(at: ReferenceStore.url(for: firstReference)) else {
            throw ReferenceStore.ImportError.missing
        }
        guard size == referenceSize else { throw MarkupError.mismatchedSize }
        guard size.width * size.height <= maxPixels else { throw MarkupError.tooManyPixels }

        let data = try Data(contentsOf: overlayURL)
        guard data.count <= maxFileSize else { throw MarkupError.fileTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == (UTType.png.identifier as CFString),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyHasAlpha] as? Bool == true else { throw MarkupError.noAlpha }
        return OpenAIImageClient.ReferenceUpload(fileName: "markup.png", mimeType: "image/png", data: data)
    }
}

/// Draws markup over its reference image, for showing them together.
nonisolated enum MarkupCompositor {
    @concurrent
    static func composite(_ base: UIImage, overlayURL: URL) async -> UIImage? {
        let longEdge = Int(max(base.size.width, base.size.height) * base.scale)
        guard let overlay = await ImageLoader.shared.image(at: overlayURL, maxPixelSize: longEdge) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = base.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: base.size)
            base.draw(in: rect)
            overlay.draw(in: rect)
        }
    }
}
