import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(Studio.self) private var studio
    @Environment(Composer.self) private var composer
    @Environment(Preferences.self) private var preferences
    @Environment(APIKeyStore.self) private var apiKeys

    @Query(sort: \GeneratedImage.createdAt, animation: .snappy) private var images: [GeneratedImage]

    @State private var path: [UUID] = []
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showingSettings = false
    @State private var pendingDeletion: [GeneratedImage] = []
    @State private var showingDeleteConfirmation = false
    @State private var inspectedJob: Studio.Job?
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @FocusState private var composerFocused: Bool
    @Namespace private var zoomNamespace

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 2)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if images.isEmpty && studio.jobs.isEmpty {
                    EmptyLibraryView(hasAPIKey: apiKeys.isConfigured) { showingSettings = true }
                } else {
                    grid
                }
            }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(isSelecting ? .inline : .inlineLarge)
            .toolbar { toolbar }
            .safeAreaBar(edge: .bottom) {
                if !isSelecting {
                    ComposerBar(isFocused: $composerFocused, onSubmit: submit)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ImageDetailView(initialID: id)
                    .navigationTransition(.zoom(sourceID: id, in: zoomNamespace))
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .confirmationDialog(deletionTitle, isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button(pendingDeletion.count == 1 ? "Delete Image" : "Delete \(pendingDeletion.count) Images", role: .destructive) {
                studio.delete(pendingDeletion)
                pendingDeletion = []
                endSelection()
            }
        }
        .alert("Generation Failed", isPresented: inspectingJob, presenting: inspectedJob) { job in
            Button("Retry") { studio.retry(job) }
            Button("Edit Prompt") {
                composer.prompt = job.prompt
                composer.setSettings(job.settings, defaults: preferences.defaults)
                studio.cancel(job)
                composerFocused = true
            }
            Button("Dismiss", role: .cancel) { studio.cancel(job) }
        } message: { job in
            if case .failed(let message) = job.state { Text(message) }
        }
        .alert("Something Went Wrong", isPresented: showingStudioAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(studio.alertMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: studio.completedCount)
        .sensoryFeedback(.error, trigger: studio.failureCount)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(images) { image in
                    tile(for: image)
                }
                ForEach(studio.jobs) { job in
                    ForEach(0..<job.settings.count, id: \.self) { _ in
                        PendingTile(job: job)
                            .onTapGesture { if job.isFailed { inspectedJob = job } }
                            .contextMenu { pendingMenu(for: job) }
                    }
                }
            }
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
    }

    private func tile(for image: GeneratedImage) -> some View {
        LibraryTile(image: image, isSelecting: isSelecting, isSelected: selection.contains(image.id))
            .matchedTransitionSource(id: image.id, in: zoomNamespace)
            .onTapGesture { tap(image) }
            .contextMenu {
                if !isSelecting {
                    ImageContextMenu(
                        image: image,
                        onRegenerate: { regenerate([image]) },
                        onReusePrompt: { reuse(image) },
                        onSelect: { beginSelection(with: image) },
                        onDelete: { confirmDeletion(of: [image]) }
                    )
                }
            } preview: {
                StoredImageView(fileName: image.fileName, maxPixelSize: 1200)
                    .aspectRatio(image.aspectRatio, contentMode: .fit)
                    .frame(width: 340)
                    .frame(maxHeight: 520)
            }
    }

    @ViewBuilder
    private func pendingMenu(for job: Studio.Job) -> some View {
        if job.isFailed {
            Button("Retry", systemImage: "arrow.clockwise") { studio.retry(job) }
            Button("Dismiss", systemImage: "xmark") { studio.cancel(job) }
        } else {
            Button("Cancel Generation", systemImage: "xmark", role: .destructive) { studio.cancel(job) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    selection = allSelected ? [] : Set(images.map(\.id))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: endSelection).fontWeight(.semibold)
            }
            ToolbarItem(placement: .bottomBar) {
                ShareLink(items: selectedImages.map(\.fileURL)) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Regenerate", systemImage: "arrow.clockwise") {
                    regenerate(selectedImages)
                    endSelection()
                }
                .disabled(selection.isEmpty)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmDeletion(of: selectedImages)
                }
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { withAnimation(.snappy) { isSelecting = true } }
                    .disabled(images.isEmpty)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
        }
    }

    // MARK: Actions

    private func submit() {
        guard apiKeys.isConfigured else {
            showingSettings = true
            return
        }
        let prompt = composer.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        studio.generate(prompt: prompt, settings: composer.settings(defaults: preferences.defaults))
        composer.prompt = ""
        composerFocused = false
        Task { withAnimation(.snappy) { scrollPosition.scrollTo(edge: .bottom) } }
    }

    private func tap(_ image: GeneratedImage) {
        if isSelecting {
            if selection.contains(image.id) { selection.remove(image.id) } else { selection.insert(image.id) }
        } else {
            path.append(image.id)
        }
    }

    private func regenerate(_ images: [GeneratedImage]) {
        guard apiKeys.isConfigured else {
            showingSettings = true
            return
        }
        studio.regenerate(images)
        Task { withAnimation(.snappy) { scrollPosition.scrollTo(edge: .bottom) } }
    }

    private func reuse(_ image: GeneratedImage) {
        composer.reuse(image, defaults: preferences.defaults)
        composerFocused = true
    }

    private func beginSelection(with image: GeneratedImage) {
        withAnimation(.snappy) {
            isSelecting = true
            selection = [image.id]
        }
    }

    private func endSelection() {
        withAnimation(.snappy) {
            isSelecting = false
            selection = []
        }
    }

    private func confirmDeletion(of images: [GeneratedImage]) {
        guard !images.isEmpty else { return }
        pendingDeletion = images
        showingDeleteConfirmation = true
    }

    // MARK: Derived state

    private var title: String {
        guard isSelecting else { return "Image Studio" }
        return selection.isEmpty ? "Select Items" : "\(selection.count) Selected"
    }

    private var selectedImages: [GeneratedImage] {
        images.filter { selection.contains($0.id) }
    }

    private var allSelected: Bool {
        !images.isEmpty && selection.count == images.count
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1
            ? "This image will be permanently deleted."
            : "These \(pendingDeletion.count) images will be permanently deleted."
    }

    private var showingStudioAlert: Binding<Bool> {
        Binding(get: { studio.alertMessage != nil }, set: { if !$0 { studio.alertMessage = nil } })
    }

    private var inspectingJob: Binding<Bool> {
        Binding(get: { inspectedJob != nil }, set: { if !$0 { inspectedJob = nil } })
    }
}

// MARK: - Empty state

private struct EmptyLibraryView: View {
    let hasAPIKey: Bool
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
            Text("Nothing here yet")
                .font(.system(.title2, design: .serif))
            Text(hasAPIKey
                 ? "Describe an image below to create your first one."
                 : "Add your OpenAI API key to start creating.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !hasAPIKey {
                Button("Add API Key", action: openSettings)
                    .buttonStyle(.glass)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
