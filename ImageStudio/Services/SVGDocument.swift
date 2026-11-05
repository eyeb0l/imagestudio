import CoreGraphics
import Foundation

/// What Image Studio knows about an SVG file, read with `XMLParser` from its root element.
///
/// The file comes from a network response, so it's treated as untrusted: only well-formed UTF-8
/// documents with an `<svg>` root in the SVG namespace are accepted, and documents that declare
/// entities are refused, which rules out entity-expansion bombs and external entities.
nonisolated struct SVGDocument: Sendable, Equatable {
    static let fileExtension = "svg"
    /// Larger files aren't rendered. Generated documents are far smaller than this.
    static let maxByteCount = 32 * 1024 * 1024
    /// Used when neither the file nor the API says how big an image is.
    static let fallbackSize = ImageSize.square

    /// Longest edge recorded in the library, which stores whole numbers.
    private static let maxRecordedEdge = 16_384.0
    /// Sizes that whole numbers can't represent are recorded at this scale, to keep their ratio.
    private static let recordedEdgeForFractionalSizes = 4096.0

    /// The size in CSS pixels, from `width`/`height` and `viewBox`. `nil` if the file doesn't say.
    let intrinsicSize: CGSize?

    /// Width divided by height. Never zero, even for a file that gives no size.
    var aspectRatio: CGFloat {
        intrinsicSize.map { $0.width / $0.height } ?? 1
    }

    /// `nil` if the data isn't a well-formed SVG document that's safe to hand to a renderer.
    init?(data: Data) {
        guard !data.isEmpty, data.count <= Self.maxByteCount,
              // OpenAI documents UTF-8. Bytes that are valid UTF-8 can still declare another encoding
              // (ASCII-only UTF-7, say) to hide markup from the search below, so that's refused too.
              let text = String(data: data, encoding: .utf8), Self.declaresOnlyUTF8(text),
              // Not every declaration reaches `XMLParserDelegate`, so look for them directly.
              // A mention in a comment is refused too, which is no loss.
              !text.contains("<!ENTITY") else { return nil }
        let reader = RootReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.foundEntityDeclaration, let root = reader.root else { return nil }
        intrinsicSize = Self.intrinsicSize(width: root["width"], height: root["height"], viewBox: root["viewBox"])
    }

    /// Whether a document's XML declaration, if it has one, names no encoding other than UTF-8.
    private static func declaresOnlyUTF8(_ text: String) -> Bool {
        let start = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        guard start.hasPrefix("<?xml"), let end = start.range(of: "?>") else { return true }
        let declaration = start[..<end.lowerBound]
        guard let match = declaration.firstMatch(of: /encoding\s*=\s*["']([^"']*)["']/) else {
            return !declaration.contains("encoding")
        }
        return ["utf-8", "utf8"].contains(match.1.lowercased())
    }

    /// `data` with `size` written into its root element, if it's an SVG that gives no size of its
    /// own. Otherwise its content has no frame to be drawn in: anything beyond the fallback canvas
    /// would be cut off. Any other document is returned as it was.
    static func addingSize(_ size: ImageSize?, to data: Data) -> Data {
        guard let size, !size.isAuto, let document = SVGDocument(data: data), document.intrinsicSize == nil,
              let text = String(data: data, encoding: .utf8),
              let root = text.firstMatch(of: /<svg(?=[\s>\/])/) else { return data }
        let sized = text.replacingCharacters(in: root.range, with: "<svg width=\"\(size.width)\" height=\"\(size.height)\"")
        // The first match might not have been the root element, or it may have other sizes that
        // don't count, such as `width="100%"`. Either way the result is only used if it's right.
        let result = Data(sized.utf8)
        return SVGDocument(data: result)?.intrinsicSize == nil ? data : result
    }

    static func isSVG(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Whether data looks like an SVG without parsing it, e.g. to refuse one where only raster
    /// images belong. It has to start as XML does, so metadata inside a photo can't trip it.
    static func looksLikeSVG(_ data: Data) -> Bool {
        let start = String(decoding: data.prefix(4096), as: UTF8.self)
        let trimmed = start.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        return trimmed.hasPrefix("<") && trimmed.lowercased().contains("<svg")
    }

    // MARK: Library dimensions

    /// The width and height to record for a file, so a view's aspect ratio is right and never
    /// zero: the file's own size, or the fallback canvas it's drawn on if it gives none (see
    /// `addingSize`). What the API reported only applies to a file that can't be read, then a default.
    /// These aren't pixels, as a vector has none, so they're for the ratio. Views shouldn't present
    /// them as resolution.
    static func dimensions(of data: Data, reported: ImageSize?) -> (width: Int, height: Int) {
        if let document = SVGDocument(data: data) {
            guard let size = document.intrinsicSize else { return (fallbackSize.width, fallbackSize.height) }
            return dimensions(for: size)
        }
        if let reported, !reported.isAuto {
            return (reported.width, reported.height)
        }
        return (fallbackSize.width, fallbackSize.height)
    }

    static func dimensions(for size: CGSize) -> (width: Int, height: Int) {
        let longEdge = max(size.width, size.height)
        let isWhole = size.width >= 1 && size.height >= 1
            && size.width.rounded() == size.width && size.height.rounded() == size.height
        let targetEdge = isWhole ? min(longEdge, maxRecordedEdge) : recordedEdgeForFractionalSizes
        let width = (size.width / longEdge * targetEdge).rounded()
        let height = (size.height / longEdge * targetEdge).rounded()
        return (max(Int(width), 1), max(Int(height), 1))
    }

    // MARK: Parsing

    /// Follows the CSS rules for an image: `width` and `height` if both are absolute, otherwise
    /// the `viewBox`, using whichever of the two it can to set the scale.
    static func intrinsicSize(width: String?, height: String?, viewBox: String?) -> CGSize? {
        let width = width.flatMap(length(from:))
        let height = height.flatMap(length(from:))
        let box = viewBox.flatMap(viewBoxSize(from:))
        let size: CGSize? = switch (width, height, box) {
        case (let width?, let height?, _): CGSize(width: width, height: height)
        case (let width?, nil, let box?): CGSize(width: width, height: width * box.height / box.width)
        case (nil, let height?, let box?): CGSize(width: height * box.width / box.height, height: height)
        case (nil, nil, let box?): box
        default: nil
        }
        guard let size, isUsable(size.width), isUsable(size.height),
              isUsable(size.width / size.height) else { return nil }
        return size
    }

    /// An absolute length in CSS pixels. `nil` for what doesn't give a size by itself: percentages,
    /// font-relative units, zero, negative values and anything that isn't a number.
    static func length(from value: String) -> CGFloat? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = value.prefix { "0123456789.+-e".contains($0) }
        // "em" starts with a character numbers can contain.
        let (number, unit) = digits.hasSuffix("e") && value.count > digits.count
            ? (digits.dropLast(), value.dropFirst(digits.count - 1))
            : (digits, value.dropFirst(digits.count))
        guard let pixelsPerUnit = cssPixels[String(unit)], let parsed = Double(number) else { return nil }
        let pixels = parsed * pixelsPerUnit
        return isUsable(pixels) ? pixels : nil
    }

    /// The width and height of a `viewBox`: four numbers separated by spaces and/or commas.
    static func viewBoxSize(from value: String) -> CGSize? {
        let parts = value.split { $0 == "," || $0.isWhitespace }
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Double? in
            guard part.allSatisfy({ "0123456789.+-eE".contains($0) }) else { return nil }
            return Double(part).flatMap { $0.isFinite ? $0 : nil }
        }
        guard numbers.count == 4, isUsable(numbers[2]), isUsable(numbers[3]) else { return nil }
        return CGSize(width: numbers[2], height: numbers[3])
    }

    private static func isUsable(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }

    private static let cssPixels: [String: Double] = [
        "": 1, "px": 1, "pt": 96.0 / 72, "pc": 16, "in": 96, "cm": 96 / 2.54, "mm": 96 / 25.4, "q": 96 / 101.6,
    ]

    private nonisolated final class RootReader: NSObject, XMLParserDelegate {
        private(set) var root: [String: String]?
        private(set) var foundEntityDeclaration = false

        private func refuseEntity(in parser: XMLParser) {
            foundEntityDeclaration = true
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            refuseEntity(in: parser)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            refuseEntity(in: parser)
        }

        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
                    systemID: String?, notationName: String?) {
            refuseEntity(in: parser)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard root == nil else { return }
            guard elementName == "svg", namespaceURI == "http://www.w3.org/2000/svg" else {
                parser.abortParsing()
                return
            }
            root = attributes
        }
    }
}
