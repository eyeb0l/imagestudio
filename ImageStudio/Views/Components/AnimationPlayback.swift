import SwiftUI
import UIKit

extension View {
    /// Plays the animation in the file at `url` into `frame` while `isActive`. `frame` is `nil`
    /// whenever nothing is playing, so the view can show its still image: when inactive, with
    /// Reduce Motion on or Auto-Play Animated Images off, or with the app in the background.
    func playsAnimation(of url: URL, isActive: Bool = true, frame: Binding<UIImage?>) -> some View {
        modifier(AnimationPlayback(url: url, isActive: isActive, frame: frame))
    }
}

private struct AnimationPlayback: ViewModifier {
    let url: URL
    let isActive: Bool
    @Binding var frame: UIImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Equatable {
        let url: URL
        let isPlaying: Bool
    }

    func body(content: Content) -> some View {
        let isPlaying = isActive && !reduceMotion && playAnimatedImages && scenePhase == .active
        content.task(id: Key(url: url, isPlaying: isPlaying)) {
            guard isPlaying else {
                frame = nil
                return
            }
            await AnimatedImageDecoder.play(url: url) { frame = $0 }
        }
    }
}
