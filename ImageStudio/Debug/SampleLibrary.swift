#if DEBUG
import SwiftData
import UIKit

/// Seeds an empty library with locally rendered placeholder images so the UI can be
/// exercised without spending API credit. Enable with the `-SeedSampleLibrary` launch
/// argument (toggle it in the ImageStudio scheme's Run arguments).
enum SampleLibrary {
    static func seedIfRequested(context: ModelContext, studio: Studio) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-SeedPendingJobs") { studio.addSampleJobs() }
        guard arguments.contains("-SeedSampleLibrary") else { return }
        guard ((try? context.fetchCount(FetchDescriptor<GeneratedImage>())) ?? 0) == 0 else { return }

        let start = Date.now.addingTimeInterval(-Double(samples.count) * 3600)
        for (index, sample) in samples.enumerated() {
            let data = render(width: sample.width, height: sample.height, colors: sample.colors)
            let fileName = ImageStore.makeFileName(format: .png, date: start)
            try? data.write(to: ImageStore.url(for: fileName))

            var settings = GenerationSettings()
            settings.size = ImageSize(width: sample.width, height: sample.height)
            settings.quality = .high
            context.insert(GeneratedImage(
                createdAt: start.addingTimeInterval(Double(index) * 3600),
                prompt: sample.prompt,
                settings: settings,
                width: sample.width,
                height: sample.height,
                resolvedQuality: "high",
                resolvedBackground: "opaque",
                fileName: fileName,
                fileSize: data.count,
                batchID: UUID(),
                duration: Double(18 + index * 3),
                inputTokens: 40 + index,
                outputTokens: 4160
            ))
        }
        try? context.save()
    }

    private struct Sample {
        let prompt: String
        let width: Int
        let height: Int
        let colors: [UIColor]
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static let samples: [Sample] = [
        Sample(prompt: "A quiet harbour at dawn, pastel fog over still water, small wooden boats, soft film grain",
               width: 1536, height: 1024, colors: [color(0xF4D8C8), color(0xB9C7D9), color(0x6E7F99)]),
        Sample(prompt: "Minimal ceramic vase on a linen tablecloth, late afternoon window light, muted earth tones",
               width: 1024, height: 1536, colors: [color(0xE9DFD1), color(0xC59B76), color(0x5A4636)]),
        Sample(prompt: "Aerial view of a desert canyon at golden hour, long shadows, ochre and rust",
               width: 1024, height: 1024, colors: [color(0xF2B66D), color(0xC2552E), color(0x3D1F1A)]),
        Sample(prompt: "Bioluminescent jellyfish drifting through deep blue water, macro photography",
               width: 1024, height: 1024, colors: [color(0x0B1D3A), color(0x1F5C8C), color(0x8FE3F2)]),
        Sample(prompt: "Brutalist concrete library interior with a single beam of light, architectural photography",
               width: 1536, height: 864, colors: [color(0xD9D6D0), color(0x8E8A84), color(0x2F2D2B)]),
        Sample(prompt: "A field of lavender under a thunderstorm sky, cinematic, wide angle",
               width: 1536, height: 1024, colors: [color(0x2E2A4F), color(0x7A6FB0), color(0xC9B8E8)]),
        Sample(prompt: "Isometric illustration of a tiny greenhouse full of plants, soft gradients",
               width: 1024, height: 1024, colors: [color(0xDFF2E1), color(0x7CC49A), color(0x2F6B4F)]),
        Sample(prompt: "Portrait of an elderly fisherman, weathered face, Rembrandt lighting, oil painting",
               width: 1024, height: 1536, colors: [color(0x1C1714), color(0x7A4E2E), color(0xE0B988)]),
        Sample(prompt: "Neon-lit rainy street in Tokyo at night, reflections on wet asphalt",
               width: 864, height: 1536, colors: [color(0x120A24), color(0xD6338A), color(0x2FD3E0)]),
    ]

    private static func render(width: Int, height: Int, colors: [UIColor]) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let linear = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil)!
            cg.drawLinearGradient(linear, start: .zero, end: CGPoint(x: size.width * 0.3, y: size.height),
                                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

            // A few soft glows for depth.
            for (index, color) in colors.enumerated() {
                let center = CGPoint(x: size.width * [0.25, 0.75, 0.5][index % 3],
                                     y: size.height * [0.3, 0.45, 0.8][index % 3])
                let glow = CGGradient(colorsSpace: space,
                                      colors: [color.withAlphaComponent(0.7).cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, 1])!
                cg.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center,
                                      endRadius: max(size.width, size.height) * 0.45, options: [])
            }
        }
        return image.pngData() ?? Data()
    }
}
#endif
