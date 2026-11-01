import Foundation
import ImageIO
import UIKit

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

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    static func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
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
        cache.object(forKey: Self.key(fileName, maxPixelSize))
    }

    @concurrent
    func image(fileName: String, maxPixelSize: Int) async -> UIImage? {
        let key = Self.key(fileName, maxPixelSize)
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = Self.downsample(url: ImageStore.url(for: fileName), maxPixelSize: maxPixelSize) else {
            return nil
        }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    private static func key(_ fileName: String, _ maxPixelSize: Int) -> NSString {
        "\(fileName)#\(maxPixelSize)" as NSString
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
