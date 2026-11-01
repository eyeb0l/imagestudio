import SwiftUI

/// A brief, non-blocking message.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    var systemImage = "exclamationmark.circle"

    static let copyFailed = Toast(message: "Couldn't copy the image")
}

extension View {
    /// Shows `toast` in a glass capsule near the top of the view, then clears it.
    func toast(_ toast: Binding<Toast?>) -> some View {
        modifier(ToastModifier(toast: toast))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    Label(toast.message, systemImage: toast.systemImage)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: toast)
            .sensoryFeedback(.error, trigger: toast) { _, new in new != nil }
            .task(id: toast) {
                guard toast != nil else { return }
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { toast = nil }
            }
    }
}
