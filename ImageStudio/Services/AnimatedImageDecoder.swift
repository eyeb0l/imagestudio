import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Reads an animated GIF's timing and decodes its frames off the main thread.
///
/// Frames are decoded one at a time and never cached, so memory use doesn't grow with the length
/// of the animation: playback holds the frame on screen and the one about to replace it.
actor AnimatedImageDecoder {
    /// Longest edge of decoded frames. Bounds playback memory to about 32 MB.
    nonisolated static let maxPlaybackPixelSize = 2048
    /// Used for frames with no usable delay. Browsers treat these the same way.
    nonisolated static let fallbackDelay: TimeInterval = 0.1

    /// How long each frame stays on screen, in file order.
    nonisolated let frameDelays: [TimeInterval]
    private let source: CGImageSource

    /// `nil` if the data isn't a GIF.
    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, Self.sourceOptions) else { return nil }
        self.init(source: source)
    }

    /// `nil` if the file can't be read or isn't a GIF.
    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, Self.sourceOptions) else { return nil }
        self.init(source: source)
    }

    private init?(source: CGImageSource) {
        guard let type = CGImageSourceGetType(source), type as String == UTType.gif.identifier else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        self.source = source
        frameDelays = (0..<count).map { index in
            Self.delay(from: CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
        }
    }

    /// Decodes one complete frame (frames that only update part of the image are composited by
    /// ImageIO), downsampled to `maxPixelSize`.
    func frame(at index: Int, maxPixelSize: Int = AnimatedImageDecoder.maxPlaybackPixelSize) -> UIImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, index, options).map { UIImage(cgImage: $0) }
    }

    /// Loops the animation until the task is cancelled, calling `show` as each frame comes due.
    /// Returns at once for anything that isn't an animated GIF. If a frame takes longer to decode
    /// than its delay, playback runs late rather than blocking the main thread.
    @MainActor
    static func play(url: URL, maxPixelSize: Int = maxPlaybackPixelSize, show: (UIImage) -> Void) async {
        guard let decoder = await open(url: url), decoder.frameDelays.count > 1 else { return }
        let delays = decoder.frameDelays
        let clock = ContinuousClock()
        var deadline = clock.now
        var index = 0
        while !Task.isCancelled {
            guard let frame = await decoder.frame(at: index, maxPixelSize: maxPixelSize) else { return }
            do { try await clock.sleep(until: deadline) } catch { return }
            show(frame)
            // Stay on the file's timing, but don't race to catch up after a pause.
            deadline = max(deadline + .seconds(delays[index]), clock.now)
            index = (index + 1) % delays.count
        }
    }

    @concurrent
    private nonisolated static func open(url: URL) async -> AnimatedImageDecoder? {
        AnimatedImageDecoder(url: url)
    }

    nonisolated private static func delay(from properties: [CFString: Any]?) -> TimeInterval {
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        // The clamped value turns short delays into 100 ms, so prefer the file's actual value.
        let candidates = [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime]
        // A stored delay of 0 or 10 ms usually means "unspecified", not "as fast as possible".
        return candidates.lazy.compactMap { gif?[$0] as? Double }.first { $0 > 0.01 } ?? fallbackDelay
    }

    nonisolated private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }
}
