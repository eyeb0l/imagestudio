import SwiftUI
import UIKit

extension GeneratedImage {
    /// Whether the original file is still on disk. Export and copy need it.
    var fileIsAvailable: Bool {
        FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    }

    /// Copies the original file to the pasteboard, preserving its format. Returns `false`
    /// if the file couldn't be read.
    @discardableResult
    func copyToPasteboard() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        UIPasteboard.general.setData(data, forPasteboardType: format.contentType.identifier)
        return true
    }
}

/// Long-press menu actions for a library image.
struct ImageContextMenu: View {
    let image: GeneratedImage
    var onRegenerate: () -> Void
    var onReusePrompt: () -> Void
    var onSelect: (() -> Void)?
    var onDelete: () -> Void
    var onNotice: (Toast) -> Void = { _ in }

    var body: some View {
        let available = image.fileIsAvailable
        ShareLink(item: image.fileURL) {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(!available)
        Button("Copy", systemImage: "doc.on.doc") {
            if !image.copyToPasteboard() { onNotice(.copyFailed) }
        }
        .disabled(!available)
        Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
        Button("Reuse Prompt", systemImage: "text.cursor", action: onReusePrompt)
        if let onSelect {
            Button("Select", systemImage: "checkmark.circle", action: onSelect)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
}
