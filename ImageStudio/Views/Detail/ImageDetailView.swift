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
                    // Neighbouring pages are kept ready for swiping, but only the one in view animates.
                    ImageDetailPage(image: image, isInView: image.id == (currentID ?? initialID) && fullscreen == nil) {
                        fullscreen = $0
                    }
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
        .fullScreenCover(item: $fullscreen) { FullscreenImageViewer(url: $0.url, overlayURL: $0.overlayURL) }
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
                    .disabled(!current.fileIsAvailable || composer.remainingReferenceSlots == 0
                              || !current.format.canBeReference)
                    Button("Mark Up", systemImage: "pencil.tip.crop.circle") {
                        let image = current
                        Task { await composer.beginMarkup(from: image) }
                        dismiss()
                    }
                    .disabled(!current.fileIsAvailable || composer.remainingReferenceSlots == 0
                              || !current.format.canBeReference)
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
    let isInView: Bool
    /// Opens a file (this image or one of its references) full screen.
    var onOpenFullscreen: (FullscreenItem) -> Void

    var body: some View {
        let fileIsMissing = !image.fileIsAvailable
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                StoredImageView(fileName: image.fileName, maxPixelSize: FullscreenImageViewer.detailPixelSize, contentMode: .fit,
                                animates: image.format.isAnimated && isInView)
                    .aspectRatio(image.aspectRatio, contentMode: .fit)
                    .transparencyBackdrop(for: image)
                    .frame(maxWidth: .infinity, maxHeight: 460)
                    .contentShape(.rect)
                    .onTapGesture { onOpenFullscreen(FullscreenItem(url: image.fileURL)) }
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
                                    if let markup = image.markupFileName, let first = image.referenceFileNames.first {
                                        MarkupTile(reference: first, markup: markup, onOpenFullscreen: onOpenFullscreen)
                                    }
                                    ForEach(image.referenceFileNames, id: \.self) { name in
                                        Button {
                                            onOpenFullscreen(FullscreenItem(url: ReferenceStore.url(for: name)))
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

/// The first reference with the markup drawn on it. Tap to see them together, full screen.
private struct MarkupTile: View {
    let reference: String
    let markup: String
    var onOpenFullscreen: (FullscreenItem) -> Void

    var body: some View {
        Button {
            onOpenFullscreen(FullscreenItem(url: ReferenceStore.url(for: reference),
                                            overlayURL: ReferenceStore.url(for: markup)))
        } label: {
            ReferenceThumbnail(fileName: reference, size: 72, markupFileName: markup)
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "pencil.tip")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.tint, in: .circle)
                        .padding(4)
                }
        }
        .buttonStyle(.plain)
        .disabled(!ReferenceStore.fileExists(reference) || !ReferenceStore.fileExists(markup))
        .accessibilityLabel("Markup. Double tap to view it on the first reference.")
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
            if image.format.isVector {
                // The API reports authoring separately from image rendering, and may not report it.
                Text("Quality and complexity apply to the reference image OpenAI creates first, and Tokens are for that image. Writing the SVG is billed separately, at the author model's rates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Model", image.modelDisplayName),
            ("Size", sizeLabel),
        ]
        if image.format.isVector, let requested = ImageSize(apiValue: image.requestedSize), !requested.isAuto {
            rows.append(("Requested", requested.dimensionsLabel))
        }
        rows += [
            ("Quality", resolved(requested: image.quality, actual: image.resolvedQuality)),
        ]
        if let complexity = image.complexity {
            rows.append(("Complexity", displayName(complexity)))
        }
        if let frameCount = image.frameCount, let duration = image.frameDurationMs, image.format.isAnimated {
            rows.append(("Frames", frameCount.formatted()))
            rows.append(("Frame Duration", "\(duration.formatted()) ms"))
        }
        rows += [
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
        if let author = image.svgAuthorModel {
            rows.append(("SVG Author", SVGAuthorModel(rawValue: author)?.displayName ?? author))
        }
        if let input = image.svgInputTokens, let output = image.svgOutputTokens {
            rows.append(("Author Tokens", "\(input.formatted()) in · \(output.formatted()) out"))
        }
        return rows
    }

    private var sizeLabel: String {
        // A vector has no resolution. Its recorded dimensions only give its shape.
        if image.format.isVector {
            return "Vector · \(ImageSize(width: image.width, height: image.height).aspectRatioLabel)"
        }
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
