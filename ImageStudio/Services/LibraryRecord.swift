import CloudKit
import Foundation

/// A library image as it arrives from iCloud: its record's values, and where CloudKit put its files.
/// The files are temporary, so they're copied into the library before the record is inserted.
nonisolated struct SyncedImage: Sendable {
    var id: UUID
    var createdAt: Date
    var prompt: String
    var revisedPrompt: String?
    var modelID: String
    var requestedSize: String
    var quality: String
    var complexity: String?
    var svgAuthorModel: String?
    var svgInputTokens: Int?
    var svgOutputTokens: Int?
    var background: String
    var outputFormat: String
    var outputCompression: Int?
    var moderation: String
    var frameCount: Int?
    var frameDurationMs: Int?
    var width: Int
    var height: Int
    var resolvedQuality: String?
    var resolvedBackground: String?
    var fileName: String
    var fileSize: Int
    var batchID: UUID
    var duration: TimeInterval
    var inputTokens: Int?
    var outputTokens: Int?
    var referenceFileNames: [String]
    var markupFileName: String?

    /// The image file.
    var file: URL
    /// Files for `ReferenceStore` (references and markup) that came with the record, by name.
    var storeFiles: [String: URL]

    /// Every file in `ReferenceStore` the image relies on.
    var referenceStoreFileNames: [String] {
        referenceFileNames + MarkupStore.fileNames(forOverlay: markupFileName)
    }
}

/// How library images are stored in iCloud: one record per image in a private zone, holding its
/// details, its file and the reference and markup files it was made from.
///
/// Library images never change once they're made, so a record is only ever created or deleted.
/// Each record carries its own copies of its reference files rather than sharing them, so it can
/// be applied on its own, in any order, without the receiving device tracking shared files.
nonisolated enum LibraryRecord {
    static let containerIdentifier = "iCloud.com.eyeb0l.ImageStudio"
    static let zoneID = CKRecordZone.ID(zoneName: "Library", ownerName: CKCurrentUserDefaultName)
    static let recordType = "Image"

    private enum Key {
        static let createdAt = "createdAt"
        static let prompt = "prompt"
        static let revisedPrompt = "revisedPrompt"
        static let modelID = "modelID"
        static let requestedSize = "requestedSize"
        static let quality = "quality"
        static let complexity = "complexity"
        static let svgAuthorModel = "svgAuthorModel"
        static let svgInputTokens = "svgInputTokens"
        static let svgOutputTokens = "svgOutputTokens"
        static let background = "background"
        static let outputFormat = "outputFormat"
        static let outputCompression = "outputCompression"
        static let moderation = "moderation"
        static let frameCount = "frameCount"
        static let frameDurationMs = "frameDurationMs"
        static let width = "width"
        static let height = "height"
        static let resolvedQuality = "resolvedQuality"
        static let resolvedBackground = "resolvedBackground"
        static let fileName = "fileName"
        static let fileSize = "fileSize"
        static let batchID = "batchID"
        static let duration = "duration"
        static let inputTokens = "inputTokens"
        static let outputTokens = "outputTokens"
        static let referenceFileNames = "referenceFileNames"
        static let markupFileName = "markupFileName"
        static let file = "file"
        static let storeFileNames = "storeFileNames"
        static let storeFiles = "storeFiles"
    }

    static func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    static func imageID(of recordID: CKRecord.ID) -> UUID? {
        guard recordID.zoneID == zoneID else { return nil }
        return UUID(uuidString: recordID.recordName)
    }

    /// A record for a library image, or `nil` if its file isn't on this device. Reference and markup
    /// files that are missing are left out; the image still lists them, as it does here.
    @MainActor
    static func record(for image: GeneratedImage, imageDirectory: URL = ImageStore.directory,
                       referenceDirectory: URL = ReferenceStore.directory) -> CKRecord? {
        let fileManager = FileManager.default
        let file = imageDirectory.appending(path: image.fileName, directoryHint: .notDirectory)
        guard isSafeFileName(image.fileName), fileManager.fileExists(atPath: file.path(percentEncoded: false)) else {
            return nil
        }

        let record = CKRecord(recordType: recordType, recordID: recordID(for: image.id))
        record[Key.createdAt] = image.createdAt
        // Prompts are the most personal part of a record, so they're end-to-end encrypted.
        record.encryptedValues[Key.prompt] = image.prompt
        record.encryptedValues[Key.revisedPrompt] = image.revisedPrompt
        record[Key.modelID] = image.modelID
        record[Key.requestedSize] = image.requestedSize
        record[Key.quality] = image.quality
        record[Key.complexity] = image.complexity
        record[Key.svgAuthorModel] = image.svgAuthorModel
        record[Key.svgInputTokens] = image.svgInputTokens
        record[Key.svgOutputTokens] = image.svgOutputTokens
        record[Key.background] = image.background
        record[Key.outputFormat] = image.outputFormat
        record[Key.outputCompression] = image.outputCompression
        record[Key.moderation] = image.moderation
        record[Key.frameCount] = image.frameCount
        record[Key.frameDurationMs] = image.frameDurationMs
        record[Key.width] = image.width
        record[Key.height] = image.height
        record[Key.resolvedQuality] = image.resolvedQuality
        record[Key.resolvedBackground] = image.resolvedBackground
        record[Key.fileName] = image.fileName
        record[Key.fileSize] = image.fileSize
        record[Key.batchID] = image.batchID.uuidString
        record[Key.duration] = image.duration
        record[Key.inputTokens] = image.inputTokens
        record[Key.outputTokens] = image.outputTokens
        if !image.referenceFileNames.isEmpty { record[Key.referenceFileNames] = image.referenceFileNames }
        record[Key.markupFileName] = image.markupFileName
        record[Key.file] = CKAsset(fileURL: file)

        let present = image.referenceStoreFileNames
            .filter(isSafeFileName)
            .map { ($0, referenceDirectory.appending(path: $0, directoryHint: .notDirectory)) }
            .filter { fileManager.fileExists(atPath: $0.1.path(percentEncoded: false)) }
        if !present.isEmpty {
            record[Key.storeFileNames] = present.map(\.0)
            record[Key.storeFiles] = present.map { CKAsset(fileURL: $0.1) }
        }
        return record
    }

    /// The image a record describes, or `nil` if it isn't a usable image record. Records come from
    /// the user's own iCloud, but file names are still checked, as they become paths on this device.
    static func decode(_ record: CKRecord) -> SyncedImage? {
        guard record.recordType == recordType,
              let id = imageID(of: record.recordID),
              let createdAt = record[Key.createdAt] as? Date,
              let prompt = record.encryptedValues[Key.prompt] as? String,
              let modelID = record[Key.modelID] as? String,
              let requestedSize = record[Key.requestedSize] as? String,
              let quality = record[Key.quality] as? String,
              let background = record[Key.background] as? String,
              let outputFormat = record[Key.outputFormat] as? String,
              let moderation = record[Key.moderation] as? String,
              let width = record[Key.width] as? Int,
              let height = record[Key.height] as? Int,
              let fileName = record[Key.fileName] as? String, isSafeFileName(fileName),
              let fileSize = record[Key.fileSize] as? Int,
              let batchID = (record[Key.batchID] as? String).flatMap(UUID.init(uuidString:)),
              let duration = record[Key.duration] as? Double,
              let file = (record[Key.file] as? CKAsset)?.fileURL
        else { return nil }

        let referenceFileNames = (record[Key.referenceFileNames] as? [String]) ?? []
        let markupFileName = record[Key.markupFileName] as? String
        guard referenceFileNames.allSatisfy(isSafeFileName), markupFileName.map(isSafeFileName) ?? true else { return nil }

        var image = SyncedImage(
            id: id, createdAt: createdAt, prompt: prompt,
            revisedPrompt: record.encryptedValues[Key.revisedPrompt] as? String,
            modelID: modelID, requestedSize: requestedSize, quality: quality,
            complexity: record[Key.complexity] as? String,
            svgAuthorModel: record[Key.svgAuthorModel] as? String,
            svgInputTokens: record[Key.svgInputTokens] as? Int,
            svgOutputTokens: record[Key.svgOutputTokens] as? Int,
            background: background, outputFormat: outputFormat,
            outputCompression: record[Key.outputCompression] as? Int,
            moderation: moderation,
            frameCount: record[Key.frameCount] as? Int,
            frameDurationMs: record[Key.frameDurationMs] as? Int,
            width: width, height: height,
            resolvedQuality: record[Key.resolvedQuality] as? String,
            resolvedBackground: record[Key.resolvedBackground] as? String,
            fileName: fileName, fileSize: fileSize, batchID: batchID, duration: duration,
            inputTokens: record[Key.inputTokens] as? Int,
            outputTokens: record[Key.outputTokens] as? Int,
            referenceFileNames: referenceFileNames, markupFileName: markupFileName,
            file: file, storeFiles: [:]
        )

        // Only files the image itself refers to, so a record can't put anything else in the folder.
        let wanted = Set(image.referenceStoreFileNames)
        let names = (record[Key.storeFileNames] as? [String]) ?? []
        let assets = (record[Key.storeFiles] as? [CKAsset]) ?? []
        for (name, asset) in zip(names, assets) where wanted.contains(name) {
            if let url = asset.fileURL { image.storeFiles[name] = url }
        }
        return image
    }

    /// A plain file name: no folders, nothing hidden, nothing that leaves the directory.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0") && !name.contains(":")
    }
}

extension GeneratedImage {
    /// A library record for an image that arrived from iCloud.
    convenience init(synced image: SyncedImage) {
        self.init(id: image.id, createdAt: image.createdAt, prompt: image.prompt, revisedPrompt: image.revisedPrompt,
                  settings: GenerationSettings(), width: image.width, height: image.height,
                  resolvedQuality: image.resolvedQuality, resolvedBackground: image.resolvedBackground,
                  fileName: image.fileName, fileSize: image.fileSize, batchID: image.batchID,
                  duration: image.duration, inputTokens: image.inputTokens, outputTokens: image.outputTokens,
                  svgInputTokens: image.svgInputTokens, svgOutputTokens: image.svgOutputTokens,
                  referenceFileNames: image.referenceFileNames, markupFileName: image.markupFileName)
        // Stored as they were requested on the other device, not as this device would normalise them.
        modelID = image.modelID
        requestedSize = image.requestedSize
        quality = image.quality
        complexity = image.complexity
        svgAuthorModel = image.svgAuthorModel
        background = image.background
        outputFormat = image.outputFormat
        outputCompression = image.outputCompression
        moderation = image.moderation
        frameCount = image.frameCount
        frameDurationMs = image.frameDurationMs
    }
}
