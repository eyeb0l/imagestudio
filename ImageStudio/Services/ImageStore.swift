import Foundation
import ImageIO
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
    }

    /// Deletes every stored image, continuing past failures.
    /// Throws `ImageStoreError` if any file couldn't be removed.
    static func deleteAll() throws {
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
}

/// Decodes downsampled images off the main thread and caches them in memory.
nonisolated final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

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
        guard let image = Self.downsample(url: url, maxPixelSize: maxPixelSize) else { return nil }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
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
