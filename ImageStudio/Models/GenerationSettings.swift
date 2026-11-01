import Foundation
import UniformTypeIdentifiers

// MARK: - Model

/// Image models offered by the OpenAI Image API (`/v1/images/generations`).
/// DALL·E and `gpt-image-1` are retired and intentionally omitted.
nonisolated enum ImageModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case flare = "gpt-image-2.5-flare"
    case sunburst = "gpt-image-2.5-sunburst"
    case gptImage2 = "gpt-image-2"
    case gptImage15 = "gpt-image-1.5"
    case gptImage1Mini = "gpt-image-1-mini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flare: "GPT Image 2.5 Flare"
        case .sunburst: "GPT Image 2.5 Sunburst"
        case .gptImage2: "GPT Image 2"
        case .gptImage15: "GPT Image 1.5"
        case .gptImage1Mini: "GPT Image 1 Mini"
        }
    }

    var shortName: String {
        switch self {
        case .flare: "Flare"
        case .sunburst: "Sunburst"
        case .gptImage2: "Image 2"
        case .gptImage15: "Image 1.5"
        case .gptImage1Mini: "1 Mini"
        }
    }

    var summary: String {
        switch self {
        case .flare: "Fast, high-quality everyday images."
        case .sunburst: "Highest fidelity and precision. Slower."
        case .gptImage2: "Previous generation. Custom sizes up to 4K."
        case .gptImage15: "Earlier model. Standard sizes only."
        case .gptImage1Mini: "Lightweight and economical. Standard sizes only."
        }
    }

    /// Whether arbitrary `WIDTHxHEIGHT` sizes are accepted (vs. the three fixed sizes).
    var supportsCustomSizes: Bool {
        switch self {
        case .flare, .sunburst, .gptImage2: true
        case .gptImage15, .gptImage1Mini: false
        }
    }

    var supportedQualities: [ImageQuality] {
        switch self {
        case .flare, .sunburst: ImageQuality.allCases
        case .gptImage2, .gptImage15, .gptImage1Mini: [.auto, .low, .medium, .high]
        }
    }

    var sizePresets: [ImageSize] {
        supportsCustomSizes ? ImageSize.standardPresets + ImageSize.extendedPresets : ImageSize.standardPresets
    }
}

// MARK: - Options

nonisolated enum ImageQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, low, medium, high, xhigh, max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
}

nonisolated enum ImageBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, opaque, transparent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .opaque: "Opaque"
        case .transparent: "Transparent"
        }
    }
}

nonisolated enum OutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png, jpeg, webp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .webp: "webp"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .webp: .webP
        }
    }

    var supportsCompression: Bool { self != .png }
    var supportsTransparency: Bool { self != .jpeg }
}

nonisolated enum ModerationLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, low

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .low: "Low"
        }
    }
}

// MARK: - Size

/// A requested output size. `width == 0 && height == 0` represents `auto`.
nonisolated struct ImageSize: Hashable, Sendable, Identifiable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init?(apiValue: String) {
        let value = apiValue.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "auto" {
            self = .auto
            return
        }
        let parts = value.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0 else { return nil }
        self.init(width: width, height: height)
    }

    static let auto = ImageSize(width: 0, height: 0)
    static let square = ImageSize(width: 1024, height: 1024)
    static let landscape = ImageSize(width: 1536, height: 1024)
    static let portrait = ImageSize(width: 1024, height: 1536)

    /// Sizes every GPT Image model accepts.
    static let standardPresets: [ImageSize] = [.auto, .square, .landscape, .portrait]

    /// Extra presets for models that accept custom sizes.
    static let extendedPresets: [ImageSize] = [
        ImageSize(width: 1536, height: 864),
        ImageSize(width: 864, height: 1536),
        ImageSize(width: 2048, height: 2048),
        ImageSize(width: 2560, height: 1440),
        ImageSize(width: 1440, height: 2560),
        ImageSize(width: 3840, height: 2160),
        ImageSize(width: 2160, height: 3840),
    ]

    static let maxEdge = 3840
    static let minPixels = 655_360
    static let maxPixels = 8_294_400
    static let experimentalPixelThreshold = 2560 * 1440

    var id: String { apiValue }
    var isAuto: Bool { width <= 0 || height <= 0 }
    var apiValue: String { isAuto ? "auto" : "\(width)x\(height)" }

    var aspectRatioLabel: String {
        guard !isAuto else { return "Auto" }
        let divisor = Self.gcd(width, height)
        let (w, h) = (width / divisor, height / divisor)
        if w <= 32, h <= 32 { return "\(w):\(h)" }
        let ratio = Double(width) / Double(height)
        return ratio >= 1
            ? "\(ratio.formatted(.number.precision(.fractionLength(0...2)))):1"
            : "1:\((1 / ratio).formatted(.number.precision(.fractionLength(0...2))))"
    }

    var orientationName: String {
        if isAuto { return "Auto" }
        if width == height { return "Square" }
        return width > height ? "Landscape" : "Portrait"
    }

    var resolutionTag: String? {
        let longEdge = max(width, height)
        if longEdge >= 3000 { return "4K" }
        if longEdge >= 2000 { return "2K" }
        return nil
    }

    /// Compact label for chips, e.g. "3:2" or "16:9 · 4K".
    var shortLabel: String {
        isAuto ? "Auto" : [aspectRatioLabel, resolutionTag].compactMap(\.self).joined(separator: " · ")
    }

    /// Row title, e.g. "Landscape 3:2".
    var title: String {
        isAuto ? "Auto" : "\(orientationName) \(aspectRatioLabel)"
    }

    var dimensionsLabel: String {
        isAuto ? "Chosen by the model" : "\(width) × \(height)"
    }

    var isExperimental: Bool { !isAuto && width * height > Self.experimentalPixelThreshold }

    var isValidCustomSize: Bool {
        !isAuto && Self.validationMessage(width: width, height: height) == nil
    }

    /// Validates a custom size against the API's documented constraints.
    /// Returns a user-facing message, or `nil` if the size is valid.
    static func validationMessage(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return "Enter a width and height." }
        if width % 16 != 0 || height % 16 != 0 {
            return "Width and height must be multiples of 16."
        }
        if max(width, height) > maxEdge {
            return "Neither side can exceed \(maxEdge) px."
        }
        if Double(max(width, height)) / Double(min(width, height)) > 3 {
            return "The aspect ratio must be between 1:3 and 3:1."
        }
        let pixels = width * height
        if pixels < minPixels {
            return "Too small. The minimum is \(minPixels.formatted()) pixels, e.g. 1024 × 640."
        }
        if pixels > maxPixels {
            return "Too large. The maximum is \(maxPixels.formatted()) pixels, e.g. 3840 × 2160."
        }
        return nil
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (abs(a), abs(b))
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}

extension ImageSize: Codable {
    nonisolated init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let size = ImageSize(apiValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid size \(value)"))
        }
        self = size
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(apiValue)
    }
}

// MARK: - Settings

/// Everything needed to make a generation request, apart from the prompt.
nonisolated struct GenerationSettings: Codable, Hashable, Sendable {
    var model: ImageModel = .flare
    var size: ImageSize = .auto
    var quality: ImageQuality = .auto
    var background: ImageBackground = .auto
    var outputFormat: OutputFormat = .png
    var compression: Int = 90
    var moderation: ModerationLevel = .auto
    var count: Int = 1

    static let countRange = 1...10

    init() {}

    /// Coerces options the selected model doesn't support back to valid values.
    func normalized() -> GenerationSettings {
        var settings = self
        if !settings.model.supportedQualities.contains(settings.quality) {
            settings.quality = .high
        }
        if settings.model.supportsCustomSizes {
            if !settings.size.isAuto, !settings.size.isValidCustomSize { settings.size = .auto }
        } else if !ImageSize.standardPresets.contains(settings.size) {
            settings.size = .auto
        }
        if settings.background == .transparent, !settings.outputFormat.supportsTransparency {
            settings.outputFormat = .png
        }
        settings.compression = min(max(settings.compression, 0), 100)
        settings.count = min(max(settings.count, Self.countRange.lowerBound), Self.countRange.upperBound)
        return settings
    }

    // Decoding is lenient so a stale or partially invalid saved value
    // falls back field-by-field instead of discarding everything.
    enum CodingKeys: String, CodingKey {
        case model, size, quality, background, outputFormat, compression, moderation, count
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GenerationSettings()
        model = (try? container.decode(ImageModel.self, forKey: .model)) ?? fallback.model
        size = (try? container.decode(ImageSize.self, forKey: .size)) ?? fallback.size
        quality = (try? container.decode(ImageQuality.self, forKey: .quality)) ?? fallback.quality
        background = (try? container.decode(ImageBackground.self, forKey: .background)) ?? fallback.background
        outputFormat = (try? container.decode(OutputFormat.self, forKey: .outputFormat)) ?? fallback.outputFormat
        compression = (try? container.decode(Int.self, forKey: .compression)) ?? fallback.compression
        moderation = (try? container.decode(ModerationLevel.self, forKey: .moderation)) ?? fallback.moderation
        count = (try? container.decode(Int.self, forKey: .count)) ?? fallback.count
    }
}
