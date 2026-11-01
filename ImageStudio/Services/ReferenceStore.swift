import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stores reference images (inputs to `/images/edits`) in Application Support/References.
///
/// Each attachment gets its own file. A file is owned by the composer until it's sent, then by
/// the job and the images generated from it; `Studio` deletes it once nothing refers to it.
nonisolated enum ReferenceStore {
    /// The API accepts up to 16 input images.
    static let maxReferences = 16
    /// Longest edge after import. Keeps uploads quick while preserving plenty of detail.
    static let maxPixelSize = 2048

    enum ImportError: LocalizedError {
        case unreadable
        case missing

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be read as an image."
            case .missing: "A reference image for this generation is missing from this device."
            }
        }
    }

    static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "References", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(for fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    static func fileExists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path(percentEncoded: false))
    }

    /// Imports image data (any format ImageIO reads, e.g. HEIC from Photos), downscaled and
    /// re-encoded as JPEG, or PNG when it has transparency. Returns the new file's name.
    @concurrent
    static func importImage(_ data: Data) async throws -> String {
        let (encoded, type) = try normalize(data)
        let fileName = "\(UUID().uuidString).\(type == .png ? "png" : "jpg")"
        try encoded.write(to: url(for: fileName), options: .atomic)
        return fileName
    }

    /// Imports an image file from disk, e.g. a library image used as a reference.
    @concurrent
    static func importFile(at source: URL) async throws -> String {
        try await importImage(Data(contentsOf: source))
    }

    /// Copies an existing reference so a new owner (e.g. the composer) has its own file.
    static func duplicate(_ fileName: String) throws -> String {
        let copy = "\(UUID().uuidString).\(url(for: fileName).pathExtension)"
        try FileManager.default.copyItem(at: url(for: fileName), to: url(for: copy))
        return copy
    }

    static func delete(_ fileNames: some Sequence<String>) {
        for name in fileNames { try? FileManager.default.removeItem(at: url(for: name)) }
    }

    /// Deletes files in the directory that aren't in `referenced`.
    static func removeOrphans(keeping referenced: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        delete(orphans(in: files, referenced: referenced))
    }

    static func orphans(in files: [String], referenced: Set<String>) -> [String] {
        files.filter { !referenced.contains($0) && !$0.hasPrefix(".") }
    }

    static func mimeType(for fileName: String) -> String {
        UTType(filenameExtension: url(for: fileName).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Downscales to `maxPixelSize` (applying EXIF orientation) and encodes for upload.
    static func normalize(_ data: Data) throws -> (Data, UTType) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw ImportError.unreadable }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw ImportError.unreadable }

        let hasAlpha = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let type: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { throw ImportError.unreadable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable }
        return (output as Data, type)
    }
}
