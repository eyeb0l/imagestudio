import Foundation
import Testing
@testable import ImageStudio

@Suite("Image sizes")
struct ImageSizeTests {
    @Test func parsesAPIValues() {
        #expect(ImageSize(apiValue: "auto") == .auto)
        #expect(ImageSize(apiValue: "1536x1024") == .landscape)
        #expect(ImageSize(apiValue: " 864X1536 ") == ImageSize(width: 864, height: 1536))
        #expect(ImageSize(apiValue: "1024") == nil)
        #expect(ImageSize(apiValue: "0x1024") == nil)
        #expect(ImageSize(apiValue: "wide") == nil)
    }

    @Test func roundTripsThroughAPIValue() {
        for size in ImageSize.standardPresets + ImageSize.extendedPresets {
            #expect(ImageSize(apiValue: size.apiValue) == size)
        }
    }

    @Test func labels() {
        #expect(ImageSize.square.aspectRatioLabel == "1:1")
        #expect(ImageSize.landscape.aspectRatioLabel == "3:2")
        #expect(ImageSize(width: 3840, height: 2160).shortLabel == "16:9 · 4K")
        #expect(ImageSize(width: 2048, height: 2048).shortLabel == "1:1 · 2K")
        #expect(ImageSize.auto.shortLabel == "Auto")
        #expect(ImageSize.portrait.title == "Portrait 2:3")
    }

    @Test func allPresetsAreValid() {
        for size in ImageSize.standardPresets + ImageSize.extendedPresets where !size.isAuto {
            #expect(size.isValidCustomSize, "\(size.apiValue) should be valid")
        }
    }

    @Test(arguments: [
        (1000, 1024),  // not a multiple of 16
        (4096, 2048),  // edge too long
        (3072, 1008),  // ratio > 3:1
        (768, 768),    // too few pixels
        (3840, 2400),  // too many pixels
    ])
    func rejectsInvalidCustomSizes(width: Int, height: Int) {
        #expect(ImageSize.validationMessage(width: width, height: height) != nil)
    }

    @Test func experimentalThreshold() {
        #expect(!ImageSize(width: 2560, height: 1440).isExperimental)
        #expect(ImageSize(width: 3840, height: 2160).isExperimental)
    }
}

@Suite("Generation settings")
struct GenerationSettingsTests {
    @Test func downgradesQualityForOlderModels() {
        var settings = GenerationSettings()
        settings.quality = .max
        settings.model = .gptImage15
        #expect(settings.normalized().quality == .high)
    }

    @Test func keepsExtendedQualityForNewModels() {
        var settings = GenerationSettings()
        settings.model = .sunburst
        settings.quality = .xhigh
        #expect(settings.normalized().quality == .xhigh)
    }

    @Test func resetsCustomSizeForFixedSizeModels() {
        var settings = GenerationSettings()
        settings.size = ImageSize(width: 3840, height: 2160)
        settings.model = .gptImage1Mini
        #expect(settings.normalized().size == .auto)

        settings.size = .portrait
        #expect(settings.normalized().size == .portrait)
    }

    @Test func transparencyForcesCompatibleFormat() {
        var settings = GenerationSettings()
        settings.background = .transparent
        settings.outputFormat = .jpeg
        #expect(settings.normalized().outputFormat == .png)
    }

    @Test func clampsNumericValues() {
        var settings = GenerationSettings()
        settings.count = 40
        settings.compression = 140
        let normalized = settings.normalized()
        #expect(normalized.count == 10)
        #expect(normalized.compression == 100)
    }

    @Test func decodingIsLenient() throws {
        let json = #"{"model":"dall-e-3","size":"1536x1024","quality":"ultra","count":3}"#
        let settings = try JSONDecoder().decode(GenerationSettings.self, from: Data(json.utf8))
        #expect(settings.model == .flare)      // unknown model falls back
        #expect(settings.size == .landscape)   // valid field kept
        #expect(settings.quality == .auto)     // unknown quality falls back
        #expect(settings.count == 3)
    }

    @Test func codableRoundTrip() throws {
        var settings = GenerationSettings()
        settings.model = .gptImage2
        settings.size = ImageSize(width: 1536, height: 864)
        settings.outputFormat = .webp
        settings.compression = 70
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(GenerationSettings.self, from: data) == settings)
    }
}

@Suite("Composer")
@MainActor
struct ComposerTests {
    @Test func overridesClearWhenMatchingDefaults() {
        let composer = Composer()
        let defaults = GenerationSettings()
        var changed = defaults
        changed.count = 4

        composer.setSettings(changed, defaults: defaults)
        #expect(composer.overrides?.count == 4)
        #expect(composer.settings(defaults: defaults).count == 4)

        composer.setSettings(defaults, defaults: defaults)
        #expect(composer.overrides == nil)
    }
}
