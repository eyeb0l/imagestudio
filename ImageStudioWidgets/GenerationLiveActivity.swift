import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ImageStudioWidgets: WidgetBundle {
    var body: some Widget {
        GenerationLiveActivity()
    }
}

/// Lock Screen and Dynamic Island presentation of running generations.
struct GenerationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GenerationActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .padding(16)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusIcon(state: state)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingStatus(state: state)
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? GenerationLiveActivity.staleMessage : state.prompt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                StatusIcon(state: state)
            } compactTrailing: {
                TrailingStatus(state: state)
                    .frame(maxWidth: 44)
            } minimal: {
                StatusIcon(state: state)
            }
            .keylineTint(.primary)
        }
    }

    static let staleMessage = "Taking longer than expected. Open Image Studio to check."
}

private struct LockScreenView: View {
    let state: GenerationActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            StatusIcon(state: state)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.fill.tertiary, in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.headline)
                    if let detail = state.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Text(isStale ? GenerationLiveActivity.staleMessage : state.prompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TrailingStatus(state: state)
                .font(.title3.weight(.semibold))
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

private struct StatusIcon: View {
    let state: GenerationActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch state.phase {
        case .running: .primary
        case .succeeded: .green
        case .partiallyFailed, .failed: .orange
        }
    }
}

/// Elapsed time while running; the image count once finished.
private struct TrailingStatus: View {
    let state: GenerationActivityAttributes.ContentState

    var body: some View {
        if state.phase == .running {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else if state.savedImages > 0 {
            Label("\(state.savedImages)", systemImage: "photo.on.rectangle")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
    }
}

// MARK: - Previews

private extension GenerationActivityAttributes.ContentState {
    static let running = Self(running: 2, pendingImages: 3, savedImages: 0, failed: 0,
                              prompt: "A quiet harbour at dawn, pastel fog over still water, small wooden boats",
                              startedAt: .now.addingTimeInterval(-42), isRetrying: false)
    static let done = Self(running: 0, pendingImages: 0, savedImages: 3, failed: 0,
                           prompt: "A quiet harbour at dawn, pastel fog over still water, small wooden boats",
                           startedAt: .now, isRetrying: false)
    static let partial = Self(running: 0, pendingImages: 0, savedImages: 2, failed: 1,
                              prompt: "Minimal ceramic vase on a linen tablecloth",
                              startedAt: .now, isRetrying: false)
}

#Preview("Lock Screen", as: .content, using: GenerationActivityAttributes()) {
    GenerationLiveActivity()
} contentStates: {
    GenerationActivityAttributes.ContentState.running
    GenerationActivityAttributes.ContentState.done
    GenerationActivityAttributes.ContentState.partial
}

#Preview("Island", as: .dynamicIsland(.expanded), using: GenerationActivityAttributes()) {
    GenerationLiveActivity()
} contentStates: {
    GenerationActivityAttributes.ContentState.running
    GenerationActivityAttributes.ContentState.done
}
