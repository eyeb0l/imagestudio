import SwiftData
import SwiftUI

/// Swipeable pages showing each image with its prompt and details.
struct ImageDetailView: View {
    let initialID: UUID

    @Environment(Studio.self) private var studio
    @Environment(Composer.self) private var composer
    @Environment(Preferences.self) private var preferences
    @Environment(APIKeyStore.self) private var apiKeys
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \GeneratedImage.createdAt) private var images: [GeneratedImage]
    @State private var currentID: UUID?
    @State private var showingDeleteConfirmation = false
    @State private var fullscreen: FullscreenItem?
    @State private var showingSettings = false
    @State private var toast: Toast?

    init(initialID: UUID) {
        self.initialID = initialID
        _currentID = State(initialValue: initialID)
    }

    private var current: GeneratedImage? {
        let id = currentID ?? initialID
        return images.first { $0.id == id }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(images) { image in
                    ImageDetailPage(image: image) { fullscreen = FullscreenItem(url: $0) }
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .toast($toast)
        .navigationTitle(current?.createdAt.formatted(.dateTime.day().month(.wide).year()) ?? "")
        .navigationSubtitle(current?.createdAt.formatted(date: .omitted, time: .shortened) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .confirmationDialog("This image will be permanently deleted.", isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete Image", role: .destructive, action: deleteCurrent)
        }
        .fullScreenCover(item: $fullscreen) { FullscreenImageViewer(url: $0.url) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onChange(of: images.isEmpty) { _, isEmpty in if isEmpty { dismiss() } }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let current {
                    Button("Copy Image", systemImage: "doc.on.doc") {
                        if !current.copyToPasteboard() { toast = .copyFailed }
                    }
                    .disabled(!current.fileIsAvailable)
                    Button("Copy Prompt", systemImage: "text.quote") { UIPasteboard.general.string = current.prompt }
                    Button("Reuse Prompt", systemImage: "text.cursor") {
                        composer.reuse(current, defaults: preferences.defaults)
                        dismiss()
                    }
                    Button("Use as Reference", systemImage: "photo.badge.plus") {
                        let image = current
                        Task { await composer.addReferences(from: [image]) }
                        dismiss()
                    }
                    .disabled(!current.fileIsAvailable || composer.remainingReferenceSlots == 0)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }

        ToolbarItem(placement: .bottomBar) {
            if let current {
                ShareLink(item: current.fileURL) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!current.fileIsAvailable)
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Regenerate", systemImage: "arrow.clockwise", action: regenerateCurrent)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Delete", systemImage: "trash", role: .destructive) { showingDeleteConfirmation = true }
        }
    }

    private func regenerateCurrent() {
        guard let current else { return }
        guard apiKeys.isConfigured else {
            showingSettings = true
            return
        }
        studio.regenerate([current])
        // Head back to the library, where the new image appears as it's generated.
        dismiss()
    }

    private func deleteCurrent() {
        guard let current, let index = images.firstIndex(of: current) else { return }
        let neighbour = images[safe: index + 1] ?? images[safe: index - 1]
        if let neighbour {
            currentID = neighbour.id
            studio.delete([current])
        } else {
            dismiss()
            studio.delete([current])
        }
    }
}

// MARK: - Page

private struct ImageDetailPage: View {
    let image: GeneratedImage
    /// Opens a file (this image or one of its references) full screen.
    var onOpenFullscreen: (URL) -> Void

    var body: some View {
        let fileIsMissing = !image.fileIsAvailable
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                StoredImageView(fileName: image.fileName, maxPixelSize: 2048, contentMode: .fit)
                    .aspectRatio(image.aspectRatio, contentMode: .fit)
                    .background { if image.isTransparent { Checkerboard() } }
                    .frame(maxWidth: .infinity, maxHeight: 460)
                    .contentShape(.rect)
                    .onTapGesture { onOpenFullscreen(image.fileURL) }
                    .accessibilityLabel("Image. Double tap to view full screen.")
                    .accessibilityAddTraits(.isButton)

                if fileIsMissing {
                    Label("The image file is missing from this device.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, -12)
                }

                VStack(alignment: .leading, spacing: 28) {
                    PromptBlock(title: "Prompt", text: image.prompt)
                    if let revised = image.revisedPrompt, revised != image.prompt {
                        PromptBlock(title: "Revised Prompt", text: revised)
                    }
                    if !image.referenceFileNames.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("References")
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(image.referenceFileNames, id: \.self) { name in
                                        Button {
                                            onOpenFullscreen(ReferenceStore.url(for: name))
                                        } label: {
                                            ReferenceThumbnail(fileName: name, size: 72)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!ReferenceStore.fileExists(name))
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            .scrollClipDisabled()
                        }
                    }
                    DetailsGrid(image: image, fileIsMissing: fileIsMissing)
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }
}

private struct PromptBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            Text(text)
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

private struct DetailsGrid: View {
    let image: GeneratedImage
    let fileIsMissing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Details")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 10) {
                ForEach(rows, id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundStyle(.secondary)
                        Text(value).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.subheadline)
        }
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Model", image.modelDisplayName),
            ("Size", sizeLabel),
            ("Quality", resolved(requested: image.quality, actual: image.resolvedQuality)),
            ("Background", resolved(requested: image.background, actual: image.resolvedBackground)),
            ("Format", formatLabel),
            ("Moderation", image.moderation.capitalized),
            ("Created", image.createdAt.formatted(date: .abbreviated, time: .shortened)),
            ("Took", Duration.seconds(image.duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))),
            ("File", fileIsMissing ? "Missing" : Int64(image.fileSize).formatted(.byteCount(style: .file))),
        ]
        if let input = image.inputTokens, let output = image.outputTokens {
            rows.append(("Tokens", "\(input.formatted()) in · \(output.formatted()) out"))
        }
        return rows
    }

    private var sizeLabel: String {
        let actual = "\(image.width) × \(image.height)"
        return image.requestedSize == "auto" ? "\(actual) (Auto)" : actual
    }

    private var formatLabel: String {
        guard let compression = image.outputCompression else { return image.format.displayName }
        return "\(image.format.displayName) · \(compression)%"
    }

    /// "Auto → High" when the API reports what it chose.
    private func resolved(requested: String, actual: String?) -> String {
        let requestedLabel = displayName(requested)
        guard requested == "auto", let actual, actual != "auto" else { return requestedLabel }
        return "\(displayName(actual)) (Auto)"
    }

    private func displayName(_ raw: String) -> String {
        ImageQuality(rawValue: raw)?.displayName ?? ImageBackground(rawValue: raw)?.displayName ?? raw.capitalized
    }
}
