import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension GeneratedImage {
    /// Whether the original file is still on disk. Export and copy need it.
    var fileIsAvailable: Bool {
        FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    }

    /// Copies the original file to the pasteboard, preserving its format. Returns `false`
    /// if the file couldn't be read.
    @discardableResult
    func copyToPasteboard(_ pasteboard: UIPasteboard = .general) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        var item: [String: Any] = [format.contentType.identifier: data]
        // An SVG is also text, which is what a code editor or a note will want to paste.
        if format.isVector, let text = String(data: data, encoding: .utf8) {
            item[UTType.utf8PlainText.identifier] = text
        }
        pasteboard.items = [item]
        return true
    }
}

/// Long-press menu actions for a library image.
struct ImageContextMenu: View {
    let image: GeneratedImage
    var onRegenerate: () -> Void
    var onReusePrompt: () -> Void
    var onUseAsReference: () -> Void
    var onMarkUp: () -> Void
    /// Whether the composer has room for another reference, which Mark Up needs.
    var hasReferenceSlot = true
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
        Button("Use as Reference", systemImage: "photo.badge.plus", action: onUseAsReference)
            .disabled(!available || !image.format.canBeReference)
        Button("Mark Up", systemImage: "pencil.tip.crop.circle", action: onMarkUp)
            .disabled(!available || !image.format.canBeReference || !hasReferenceSlot)
        if let onSelect {
            Button("Select", systemImage: "checkmark.circle", action: onSelect)
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
}
