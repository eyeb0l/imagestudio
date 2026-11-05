import Foundation
import SwiftData

/// A generated image in the library. The image bytes live on disk (see `ImageStore`);
/// this record holds the prompt and everything needed to describe or regenerate it.
@Model
final class GeneratedImage {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var prompt: String
    var revisedPrompt: String?

    // Requested settings (used for regeneration).
    var modelID: String
    var requestedSize: String
    var quality: String
    /// `nil` for images from models without complexity control, and for existing libraries.
    var complexity: String?
    var background: String
    var outputFormat: String
    var outputCompression: Int?
    var moderation: String
    /// `nil` for formats without frames, and for existing libraries.
    var frameCount: Int?
    /// `nil` for formats without frames, and for existing libraries.
    var frameDurationMs: Int?

    // What the API actually produced.
    var width: Int
    var height: Int
    var resolvedQuality: String?
    var resolvedBackground: String?

    // File and request metadata.
    var fileName: String
    var fileSize: Int
    var batchID: UUID
    var duration: TimeInterval
    var inputTokens: Int?
    var outputTokens: Int?

    /// Reference images (in `ReferenceStore`) this image was generated from. Empty for plain
    /// text-to-image generations; the default lets existing libraries migrate.
    var referenceFileNames: [String] = []
    /// The annotation layer (see `MarkupStore`) drawn on the first reference. `nil` for images
    /// made without markup, and for existing libraries.
    var markupFileName: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        prompt: String,
        revisedPrompt: String? = nil,
        settings: GenerationSettings,
        width: Int,
        height: Int,
        resolvedQuality: String? = nil,
        resolvedBackground: String? = nil,
        fileName: String,
        fileSize: Int,
        batchID: UUID,
        duration: TimeInterval,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        referenceFileNames: [String] = [],
        markupFileName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.revisedPrompt = revisedPrompt
        self.modelID = settings.model.rawValue
        self.requestedSize = settings.size.apiValue
        self.quality = settings.quality.rawValue
        self.complexity = settings.apiComplexity
        self.background = settings.background.rawValue
        self.outputFormat = settings.outputFormat.rawValue
        self.outputCompression = settings.outputFormat.supportsCompression ? settings.compression : nil
        self.moderation = settings.moderation.rawValue
        self.frameCount = settings.apiFrameCount
        self.frameDurationMs = settings.apiFrameDurationMs
        self.width = width
        self.height = height
        self.resolvedQuality = resolvedQuality
        self.resolvedBackground = resolvedBackground
        self.fileName = fileName
        self.fileSize = fileSize
        self.batchID = batchID
        self.duration = duration
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.referenceFileNames = referenceFileNames
        self.markupFileName = markupFileName
    }
}

extension GeneratedImage {
    var fileURL: URL { ImageStore.url(for: fileName) }

    var format: OutputFormat { OutputFormat(rawValue: outputFormat) ?? .png }

    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    var modelDisplayName: String {
        ImageModel(rawValue: modelID)?.displayName ?? modelID
    }

    var isTransparent: Bool {
        (resolvedBackground ?? background) == ImageBackground.transparent.rawValue
    }

    /// The settings this image was requested with, for a single regeneration.
    var settings: GenerationSettings {
        var settings = GenerationSettings()
        settings.model = ImageModel(rawValue: modelID) ?? settings.model
        settings.size = ImageSize(apiValue: requestedSize) ?? .auto
        settings.quality = ImageQuality(rawValue: quality) ?? .auto
        settings.complexity = complexity.flatMap(ImageComplexity.init(rawValue:)) ?? settings.complexity
        settings.background = ImageBackground(rawValue: background) ?? .auto
        settings.outputFormat = format
        settings.compression = outputCompression ?? settings.compression
        settings.moderation = ModerationLevel(rawValue: moderation) ?? .auto
        settings.frameCount = frameCount ?? settings.frameCount
        settings.frameDurationMs = frameDurationMs ?? settings.frameDurationMs
        settings.count = 1
        return settings.normalized(hasReferences: !referenceFileNames.isEmpty, hasMarkup: markupFileName != nil)
    }

    /// Every file in `ReferenceStore` this image relies on.
    var referenceStoreFileNames: [String] {
        referenceFileNames + MarkupStore.fileNames(forOverlay: markupFileName)
    }
}
