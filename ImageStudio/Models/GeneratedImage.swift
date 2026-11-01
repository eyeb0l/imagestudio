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
    var background: String
    var outputFormat: String
    var outputCompression: Int?
    var moderation: String

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
        outputTokens: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.revisedPrompt = revisedPrompt
        self.modelID = settings.model.rawValue
        self.requestedSize = settings.size.apiValue
        self.quality = settings.quality.rawValue
        self.background = settings.background.rawValue
        self.outputFormat = settings.outputFormat.rawValue
        self.outputCompression = settings.outputFormat.supportsCompression ? settings.compression : nil
        self.moderation = settings.moderation.rawValue
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
        settings.background = ImageBackground(rawValue: background) ?? .auto
        settings.outputFormat = format
        settings.compression = outputCompression ?? settings.compression
        settings.moderation = ModerationLevel(rawValue: moderation) ?? .auto
        settings.count = 1
        return settings.normalized()
    }
}
