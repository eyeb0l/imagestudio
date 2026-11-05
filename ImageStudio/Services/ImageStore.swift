import Foundation
import ImageIO
import Synchronization
import UIKit

nonisolated enum ImageStoreError: LocalizedError {
    case deletionFailed(count: Int, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .deletionFailed(let count, let underlying):
            "\(count) image file\(count == 1 ? "" : "s") couldn't be removed from storage (\(underlying.localizedDescription))"
        }
    }
}

/// Stores original image files in Application Support/Images.
nonisolated enum ImageStore {
    static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(for fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    @concurrent
    static func save(_ data: Data, fileName: String) async throws {
        try data.write(to: url(for: fileName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Deletes a file. A file that's already gone counts as deleted.
    static func delete(fileName: String) throws {
        try removeIfExists(url(for: fileName))
        SVGRasterCache.shared.remove(fileName: fileName)
    }

    /// Deletes every stored image, continuing past failures.
    /// Throws `ImageStoreError` if any file couldn't be removed.
    static func deleteAll(in directory: URL = directory, rasterCache: SVGRasterCache = .shared) throws {
        // Caches only hold copies, so a failure below shouldn't leave them behind.
        rasterCache.removeAll()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var failed = 0
        var firstError: (any Error)?
        for file in files {
            do { try removeIfExists(file) } catch {
                failed += 1
                firstError = firstError ?? error
            }
        }
        if let firstError { throw ImageStoreError.deletionFailed(count: failed, underlying: firstError) }
    }

    private static func removeIfExists(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
        }
    }

    /// e.g. "ImageStudio-20261101-143205-3F9A2C.png" — a readable name for exports.
    static func makeFileName(format: OutputFormat, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(6)
        return "ImageStudio-\(formatter.string(from: date))-\(suffix).\(format.fileExtension)"
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// The width and height to record for a new library image. `reported` is the size in the API's
    /// response. Vectors have no pixels, so ImageIO can't read them: see `SVGDocument.dimensions`.
    static func dimensions(of data: Data, format: OutputFormat, reported: ImageSize?) -> (width: Int, height: Int) {
        if format.isVector {
            return SVGDocument.dimensions(of: data, reported: reported)
        }
        return pixelSize(of: data) ?? reported.map { ($0.width, $0.height) } ?? (0, 0)
    }
}

/// Decodes downsampled images off the main thread and caches them in memory. SVG files are rendered
/// by `SVGRasterizer` instead, and also cached on disk, so callers treat them like any other image.
nonisolated final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let rasterCache: SVGRasterCache
    private let rasterizer: @MainActor @Sendable () -> SVGRasterizer
    /// SVGs that hung the renderer. Trying each again every time it scrolls into view would tie up
    /// the renderer for all the others. Lasts until the app quits.
    private let unrenderableVectors = Mutex<Set<String>>([])

    init(rasterCache: SVGRasterCache = .shared,
         rasterizer: @escaping @MainActor @Sendable () -> SVGRasterizer = { SVGRasterizer.shared }) {
        self.rasterCache = rasterCache
        self.rasterizer = rasterizer
    }

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    func cachedImage(fileName: String, maxPixelSize: Int) -> UIImage? {
        cachedImage(at: ImageStore.url(for: fileName), maxPixelSize: maxPixelSize)
    }

    @concurrent
    func image(fileName: String, maxPixelSize: Int) async -> UIImage? {
        await image(at: ImageStore.url(for: fileName), maxPixelSize: maxPixelSize)
    }

    func cachedImage(at url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: Self.key(url, maxPixelSize))
    }

    @concurrent
    func image(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = Self.key(url, maxPixelSize)
        if let cached = cache.object(forKey: key) { return cached }
        let decoded = SVGDocument.isSVG(url)
            ? await rasterizedImage(at: url, maxPixelSize: maxPixelSize)
            : Self.downsample(url: url, maxPixelSize: maxPixelSize)
        guard let image = decoded else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// `nil` if the document can't be rendered, or can't be right now: see `SVGRasterError`.
    private func rasterizedImage(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let path = url.path(percentEncoded: false)
        guard !unrenderableVectors.withLock({ $0.contains(path) }) else { return nil }
        let cacheURL = rasterCache.url(forSource: url, maxPixelSize: maxPixelSize)
        if let cached = Self.downsample(url: cacheURL, maxPixelSize: maxPixelSize) { return cached }

        guard let data = try? Data(contentsOf: url), let document = SVGDocument(data: data) else { return nil }
        do {
            let image = try await rasterizer().rasterize(data, document: document, maxPixelSize: maxPixelSize)
            rasterCache.store(image, forSource: url, maxPixelSize: maxPixelSize)
            return image
        } catch {
            if error == .timedOut { unrenderableVectors.withLock { _ = $0.insert(path) } }
            return nil
        }
    }

    private static func key(_ url: URL, _ maxPixelSize: Int) -> NSString {
        "\(url.path(percentEncoded: false))#\(maxPixelSize)" as NSString
    }

    private static func downsample(url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
