import SwiftUI
import UIKit

extension GeneratedImage {
    /// Copies the original file to the pasteboard, preserving its format.
    func copyToPasteboard() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        UIPasteboard.general.setData(data, forPasteboardType: format.contentType.identifier)
    }
}

/// Long-press menu actions for a library image.
struct ImageContextMenu: View {
    let image: GeneratedImage
    var onRegenerate: () -> Void
    var onReusePrompt: () -> Void
    var onSelect: (() -> Void)?
    var onDelete: () -> Void

    var body: some View {
        ShareLink(item: image.fileURL) {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        Button("Copy", systemImage: "doc.on.doc") { image.copyToPasteboard() }
        Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
        Button("Reuse Prompt", systemImage: "text.cursor", action: onReusePrompt)
        if let onSelect {
            Button("Select", systemImage: "checkmark.circle", action: onSelect)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
}
