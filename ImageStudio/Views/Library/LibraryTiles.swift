import SwiftUI

/// A square thumbnail in the library grid.
struct LibraryTile: View {
    let image: GeneratedImage
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                StoredImageView(fileName: image.fileName, maxPixelSize: StoredImageView.thumbnailPixelSize)
            }
            .transparencyBackdrop(for: image, squareSize: 8)
            .clipped()
            .overlay {
                if isSelected { Color.black.opacity(0.18) }
            }
            .overlay(alignment: .bottomLeading) {
                if let badge = image.format.libraryBadge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    SelectionBadge(isSelected: isSelected)
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(.rect)
            .accessibilityElement()
            .accessibilityLabel(image.prompt)
            .accessibilityValue(image.format.libraryBadge ?? "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SelectionBadge: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.15)))
            Circle()
                .strokeBorder(.white, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
            }
        }
        .frame(width: 22, height: 22)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

/// Placeholder for an in-flight or failed generation.
struct PendingTile: View {
    let job: Studio.Job

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background {
                if job.isFailed {
                    Rectangle().fill(.fill.tertiary)
                } else {
                    ShimmerFill()
                }
            }
            .overlay { label }
            .clipped()
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var label: some View {
        switch job.state {
        case .running:
            VStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .light))
                    .symbolEffect(.breathe)
                Text(timerInterval: job.startedAt...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Generating")
        case .failed:
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .light))
                Text("Failed")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .accessibilityHint("Shows the error and lets you retry")
        }
    }
}

/// A slow sheen moving across a neutral fill.
private struct ShimmerFill: View {
    @State private var animating = false

    var body: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .primary.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.9)
                    .offset(x: animating ? proxy.size.width : -proxy.size.width * 0.9)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    animating = true
                }
            }
    }
}
