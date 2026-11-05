import Foundation
import UniformTypeIdentifiers

// MARK: - Model

/// Image models offered by the OpenAI Image API (`/v1/images/generations`).
/// DALL·E, `gpt-image-1`, `gpt-image-1.5` and `gpt-image-1-mini` are retired and intentionally omitted.
nonisolated enum ImageModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case flare26 = "gpt-image-2.6-flare"
    case sunburst26 = "gpt-image-2.6-sunburst"
    case flare25 = "gpt-image-2.5-flare"
    case sunburst25 = "gpt-image-2.5-sunburst"
    case gptImage2 = "gpt-image-2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flare26: "GPT Image 2.6 Flare"
        case .sunburst26: "GPT Image 2.6 Sunburst"
        case .flare25: "GPT Image 2.5 Flare"
        case .sunburst25: "GPT Image 2.5 Sunburst"
        case .gptImage2: "GPT Image 2"
        }
    }

    var shortName: String {
        switch self {
        case .flare26: "Flare 2.6"
        case .sunburst26: "Sunburst 2.6"
        case .flare25: "Flare 2.5"
        case .sunburst25: "Sunburst 2.5"
        case .gptImage2: "Image 2"
        }
    }

    var summary: String {
        switch self {
        case .flare26: "Fast iteration. Adjustable complexity."
        case .sunburst26: "Detailed visual work. Adjustable complexity."
        case .flare25: "Fast, high-quality everyday images."
        case .sunburst25: "Highest fidelity and precision. Slower."
        case .gptImage2: "Previous generation. Custom sizes up to 4K."
        }
    }

    var supportedQualities: [ImageQuality] {
        switch self {
        case .flare26, .sunburst26, .flare25, .sunburst25: ImageQuality.allCases
        case .gptImage2: [.auto, .low, .medium, .high]
        }
    }

    /// Whether the API accepts the `complexity` request field.
    var supportsComplexity: Bool {
        switch self {
        case .flare26, .sunburst26: true
        case .flare25, .sunburst25, .gptImage2: false
        }
    }

    /// Whether `/images/edits` accepts a `markup` annotation layer with this model.
    var supportsMarkup: Bool {
        switch self {
        case .flare26, .sunburst26, .flare25, .sunburst25: true
        case .gptImage2: false
        }
    }

    /// What a request with markup uses when its chosen model doesn't support it.
    static let markupFallback = ImageModel.flare26

    /// The models a request can use.
    static func available(hasMarkup: Bool) -> [ImageModel] {
        hasMarkup ? allCases.filter(\.supportsMarkup) : allCases
    }

    var supportedFormats: [OutputFormat] {
        switch self {
        case .flare26, .sunburst26: OutputFormat.allCases
        case .flare25, .sunburst25, .gptImage2: [.png, .jpeg, .webp]
        }
    }

    /// The formats a request can use. Reference images send it to `/images/edits`, which doesn't
    /// accept generation-only formats.
    func formats(hasReferences: Bool) -> [OutputFormat] {
        hasReferences ? supportedFormats.filter { !$0.isGenerationOnly } : supportedFormats
    }

    var sizePresets: [ImageSize] {
        ImageSize.standardPresets + ImageSize.extendedPresets
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

/// How much the model plans before rendering, independently of `ImageQuality`.
nonisolated enum ImageComplexity: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

/// The model that writes an SVG from the reference image, sent as `svg.model`. OpenAI's reference
/// takes any model name and doesn't list which ones work, so these are its current general models.
nonisolated enum SVGAuthorModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case terra = "gpt-6.1-terra"
    case sol = "gpt-6.1-sol"
    case astra = "gpt-6-astra"
    case luna = "gpt-6-luna"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terra: "GPT-6.1 Terra"
        case .sol: "GPT-6.1 Sol"
        case .astra: "GPT-6 Astra"
        case .luna: "GPT-6 Luna"
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
    case png, jpeg, webp, gif, svg

    /// What a request uses when its chosen format isn't available. Every model and endpoint takes it.
    static let fallback = OutputFormat.png

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        case .gif: "GIF"
        case .svg: "SVG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .webp: "webp"
        case .gif: "gif"
        case .svg: "svg"
        }
    }

    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .webp: .webP
        case .gif: .gif
        case .svg: .svg
        }
    }

    var supportsCompression: Bool {
        switch self {
        case .jpeg, .webp: true
        case .png, .gif, .svg: false
        }
    }

    /// Whether the API accepts `background: "transparent"` with this format. It documents that for
    /// PNG and WebP only. An SVG can still have an unpainted canvas: see `isVector`.
    var supportsTransparency: Bool {
        switch self {
        case .png, .webp: true
        case .jpeg, .gif, .svg: false
        }
    }

    /// Whether only `/images/generations` returns this format. `/images/edits` rejects it, so a
    /// request with reference images can't use it.
    var isGenerationOnly: Bool {
        switch self {
        case .gif, .svg: true
        case .png, .jpeg, .webp: false
        }
    }

    /// Whether the output has several frames: requests carry the frame settings and views play it.
    var isAnimated: Bool {
        switch self {
        case .gif: true
        case .png, .jpeg, .webp, .svg: false
        }
    }

    /// Whether the file is a document with no pixels of its own, so it has to be rendered to be
    /// shown, has no resolution to speak of, and may leave its canvas unpainted whatever the
    /// request's background was.
    var isVector: Bool {
        switch self {
        case .svg: true
        case .png, .jpeg, .webp, .gif: false
        }
    }

    /// Whether a request can ask for more than one image in this format.
    var allowsMultipleImages: Bool {
        switch self {
        case .png, .jpeg, .webp, .gif: true
        case .svg: false
        }
    }

    /// Whether a library image in this format can be sent to `/images/edits`, which takes raster
    /// images only. A GIF is sent as its first frame.
    var canBeReference: Bool {
        switch self {
        case .png, .jpeg, .webp, .gif: true
        case .svg: false
        }
    }

    /// Whether the API documents this format as needing preview access, so a 403 may be about that.
    var mayRequirePreviewAccess: Bool {
        switch self {
        case .gif: true
        case .png, .jpeg, .webp, .svg: false
        }
    }

    /// A label for library tiles, for formats a thumbnail wouldn't otherwise give away.
    var libraryBadge: String? {
        switch self {
        case .gif, .svg: displayName
        case .png, .jpeg, .webp: nil
        }
    }
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

    /// The sizes OpenAI recommends.
    static let standardPresets: [ImageSize] = [.auto, .square, .landscape, .portrait]

    /// Larger and wider presets.
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
    var model: ImageModel = .flare26
    var size: ImageSize = .auto
    var quality: ImageQuality = .auto
    /// Matches the API's default. Only sent to models that support it (see `apiComplexity`).
    var complexity: ImageComplexity = .high
    /// Only sent for SVG output (see `apiSVGAuthor`).
    var svgAuthor: SVGAuthorModel = .terra
    var background: ImageBackground = .auto
    var outputFormat: OutputFormat = .png
    var compression: Int = 90
    var moderation: ModerationLevel = .auto
    var count: Int = 1
    /// Matches the API's default. Only sent for animated formats (see `apiFrameCount`).
    var frameCount: Int = 9
    /// Matches the API's default. Only sent for animated formats (see `apiFrameDurationMs`).
    var frameDurationMs: Int = 200

    static let countRange = 1...10
    /// The guide says up to 64 frames, the API reference up to 16. Both accept this range.
    static let frameCountRange = 2...16
    static let frameDurationRange = 20...2000
    /// The API rounds frame durations to this.
    static let frameDurationStep = 10

    init() {}

    /// How many images a request in this format can ask for.
    var allowedCountRange: ClosedRange<Int> {
        outputFormat.allowsMultipleImages ? Self.countRange : 1...1
    }

    /// The value for the `svg.model` request field, or `nil` if the format isn't SVG.
    var apiSVGAuthor: String? {
        outputFormat.isVector ? svgAuthor.rawValue : nil
    }

    /// The value for the `complexity` request field, or `nil` if the model doesn't accept it.
    var apiComplexity: String? {
        model.supportsComplexity ? complexity.rawValue : nil
    }

    /// The value for the `frame_count` request field, or `nil` if the format doesn't accept it.
    var apiFrameCount: Int? {
        outputFormat.isAnimated ? frameCount : nil
    }

    /// The value for the `frame_duration_ms` request field, or `nil` if the format doesn't accept it.
    var apiFrameDurationMs: Int? {
        outputFormat.isAnimated ? frameDurationMs : nil
    }

    /// Coerces options the selected model doesn't support back to valid values. With
    /// `hasReferences`, also leaves out what `/images/edits` doesn't support. Anything that goes
    /// to that endpoint must pass `true`. `hasMarkup` also rules out models that can't take markup,
    /// which is settled first as the other options depend on the model. Markup always goes to that
    /// endpoint, so it implies `hasReferences`.
    func normalized(hasReferences: Bool = false, hasMarkup: Bool = false) -> GenerationSettings {
        var settings = self
        let hasReferences = hasReferences || hasMarkup
        if hasMarkup, !settings.model.supportsMarkup {
            settings.model = ImageModel.markupFallback
        }
        if !settings.model.formats(hasReferences: hasReferences).contains(settings.outputFormat) {
            settings.outputFormat = .fallback
        }
        if !settings.model.supportedQualities.contains(settings.quality) {
            settings.quality = .high
        }
        if !settings.model.supportsComplexity {
            settings.complexity = GenerationSettings().complexity
        }
        if !settings.size.isAuto, !settings.size.isValidCustomSize { settings.size = .auto }
        if settings.background == .transparent, !settings.outputFormat.supportsTransparency {
            settings.outputFormat = .png
        }
        if !settings.outputFormat.isVector {
            settings.svgAuthor = GenerationSettings().svgAuthor
        }
        if settings.outputFormat.isAnimated {
            let step = Self.frameDurationStep
            let duration = min(max(settings.frameDurationMs, Self.frameDurationRange.lowerBound), Self.frameDurationRange.upperBound)
            settings.frameCount = min(max(settings.frameCount, Self.frameCountRange.lowerBound), Self.frameCountRange.upperBound)
            settings.frameDurationMs = (duration + step / 2) / step * step
        } else {
            settings.frameCount = GenerationSettings().frameCount
            settings.frameDurationMs = GenerationSettings().frameDurationMs
        }
        settings.compression = min(max(settings.compression, 0), 100)
        // After the format is settled: a fallback from a single-image format can take any count.
        let counts = settings.allowedCountRange
        settings.count = min(max(settings.count, counts.lowerBound), counts.upperBound)
        return settings
    }

    // Decoding is lenient so a stale or partially invalid saved value
    // falls back field-by-field instead of discarding everything.
    enum CodingKeys: String, CodingKey {
        case model, size, quality, complexity, svgAuthor, background, outputFormat, compression, moderation, count
        case frameCount, frameDurationMs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GenerationSettings()
        model = (try? container.decode(ImageModel.self, forKey: .model)) ?? fallback.model
        size = (try? container.decode(ImageSize.self, forKey: .size)) ?? fallback.size
        quality = (try? container.decode(ImageQuality.self, forKey: .quality)) ?? fallback.quality
        complexity = (try? container.decode(ImageComplexity.self, forKey: .complexity)) ?? fallback.complexity
        svgAuthor = (try? container.decode(SVGAuthorModel.self, forKey: .svgAuthor)) ?? fallback.svgAuthor
        background = (try? container.decode(ImageBackground.self, forKey: .background)) ?? fallback.background
        outputFormat = (try? container.decode(OutputFormat.self, forKey: .outputFormat)) ?? fallback.outputFormat
        compression = (try? container.decode(Int.self, forKey: .compression)) ?? fallback.compression
        moderation = (try? container.decode(ModerationLevel.self, forKey: .moderation)) ?? fallback.moderation
        count = (try? container.decode(Int.self, forKey: .count)) ?? fallback.count
        frameCount = (try? container.decode(Int.self, forKey: .frameCount)) ?? fallback.frameCount
        frameDurationMs = (try? container.decode(Int.self, forKey: .frameDurationMs)) ?? fallback.frameDurationMs
    }
}
