import Observation
import PencilKit
import SwiftUI
import UIKit

/// An undo and redo history of values, recorded as they change.
struct MarkupHistory<Value: Equatable> {
    private(set) var current: Value
    private var undoStack: [Value] = []
    private var redoStack: [Value] = []

    init(_ initial: Value) {
        current = initial
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// A value the same as the current one isn't a change, whoever reports it.
    mutating func record(_ value: Value) {
        guard value != current else { return }
        undoStack.append(current)
        redoStack = []
        current = value
    }

    mutating func undo() -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        return previous
    }

    mutating func redo() -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        current = next
        return next
    }
}

/// A drawing in the history, compared by its strokes. `PKDrawing`'s own `==` can't tell whether
/// anything has changed: a drawing read back from a canvas can differ from the one it was given.
struct MarkupSnapshot: Equatable {
    private struct StrokeKey: Equatable {
        let created: Date
        let pointCount: Int
        let first: CGPoint?
        let last: CGPoint?
    }

    let drawing: PKDrawing
    private let strokes: [StrokeKey]

    init(_ drawing: PKDrawing) {
        self.drawing = drawing
        strokes = drawing.strokes.map { stroke in
            let path = stroke.path
            return StrokeKey(created: path.creationDate, pointCount: path.count,
                             first: path.first?.location, last: path.last?.location)
        }
    }

    static func == (a: MarkupSnapshot, b: MarkupSnapshot) -> Bool {
        a.strokes == b.strokes
    }
}

enum MarkupInk: CaseIterable, Identifiable {
    case red, yellow, green, blue

    var id: Self { self }

    var color: UIColor {
        switch self {
        case .red: UIColor(red: 0.96, green: 0.14, blue: 0.14, alpha: 1)
        case .yellow: UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
        case .green: UIColor(red: 0.13, green: 0.82, blue: 0.32, alpha: 1)
        case .blue: UIColor(red: 0.1, green: 0.47, blue: 1, alpha: 1)
        }
    }

    var accessibilityName: String {
        switch self {
        case .red: "Red Pen"
        case .yellow: "Yellow Pen"
        case .green: "Green Pen"
        case .blue: "Blue Pen"
        }
    }
}

enum MarkupLineWidth: CaseIterable, Identifiable {
    case thin, medium, thick

    var id: Self { self }

    /// In canvas units, so a line is the same on the image whatever the screen. See `MarkupGeometry`.
    var canvasWidth: CGFloat {
        switch self {
        case .thin: 1
        case .medium: 2
        case .thick: 4
        }
    }

    var dotSize: CGFloat {
        switch self {
        case .thin: 5
        case .medium: 9
        case .thick: 14
        }
    }

    var accessibilityName: String {
        switch self {
        case .thin: "Thin Line"
        case .medium: "Medium Line"
        case .thick: "Thick Line"
        }
    }
}

/// The image and the canvas above it, which always covers exactly the image's fitted rectangle.
/// The canvas's frame and zoom are worked out here, so they survive rotation with the strokes in place.
final class MarkupCanvasContainerView: UIView {
    let geometry: MarkupGeometry
    let imageView = UIImageView()
    let canvas = PKCanvasView()
    /// The strokes to restore. A canvas given a drawing before it has a size never shows it, so it
    /// gets them at the first layout.
    private var pendingDrawing: PKDrawing?

    init(geometry: MarkupGeometry, drawing: PKDrawing) {
        self.geometry = geometry
        pendingDrawing = drawing
        super.init(frame: .zero)
        imageView.contentMode = .scaleToFill
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.bouncesZoom = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        // Ink colours otherwise adapt to the appearance. This one matches the exported file.
        canvas.overrideUserInterfaceStyle = .light
        canvas.accessibilityLabel = "Drawing Canvas"
        addSubview(imageView)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fitted = geometry.fittedRect(in: bounds)
        imageView.frame = fitted
        canvas.frame = fitted
        let zoom = geometry.zoomScale(for: fitted)
        canvas.minimumZoomScale = zoom
        canvas.maximumZoomScale = zoom
        canvas.zoomScale = zoom
        canvas.contentSize = fitted.size
        canvas.contentOffset = .zero
        if let pendingDrawing {
            self.pendingDrawing = nil
            canvas.drawing = pendingDrawing
        }
    }
}

/// What the canvas is doing. Owns the canvas view, so it outlives any layout change in SwiftUI.
@Observable
final class MarkupEditorModel: NSObject, PKCanvasViewDelegate {
    let geometry: MarkupGeometry
    /// Whether there was markup to restore but its strokes couldn't be read.
    let couldNotRestore: Bool
    @ObservationIgnored let container: MarkupCanvasContainerView

    private(set) var history: MarkupHistory<MarkupSnapshot>
    private let initial: MarkupSnapshot

    var ink = MarkupInk.red { didSet { isErasing = false; applyTool() } }
    var lineWidth = MarkupLineWidth.medium { didSet { isErasing = false; applyTool() } }
    var isErasing = false { didSet { applyTool() } }

    var hasChanges: Bool { history.current != initial }
    var isEmpty: Bool { history.current.drawing.strokes.isEmpty }

    init(geometry: MarkupGeometry, drawing: PKDrawing?, couldNotRestore: Bool) {
        self.geometry = geometry
        self.couldNotRestore = couldNotRestore
        let drawing = drawing ?? PKDrawing()
        initial = MarkupSnapshot(drawing)
        history = MarkupHistory(initial)
        container = MarkupCanvasContainerView(geometry: geometry, drawing: drawing)
        super.init()
        container.canvas.delegate = self
        applyTool()
    }

    func undo() {
        if let snapshot = history.undo() { container.canvas.drawing = snapshot.drawing }
    }

    func redo() {
        if let snapshot = history.redo() { container.canvas.drawing = snapshot.drawing }
    }

    func clear() {
        let empty = PKDrawing()
        container.canvas.drawing = empty
        history.record(MarkupSnapshot(empty))
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // This also reports the changes made above, which `record` knows are nothing new.
        history.record(MarkupSnapshot(canvasView.drawing))
    }

    /// The overlay's name, or `nil` for no markup. With nothing changed, the markup stays as it
    /// was, even if its strokes couldn't be restored for editing.
    func save(existingOverlay: String?) async throws -> String? {
        guard hasChanges else { return existingOverlay }
        let drawing = history.current.drawing
        guard let overlay = try await MarkupExporter.overlayPNG(from: drawing, geometry: geometry) else { return nil }
        return try MarkupStore.save(overlay: overlay, drawing: drawing.dataRepresentation())
    }

    private func applyTool() {
        container.canvas.tool = isErasing
            ? PKEraserTool(.vector)
            : PKInkingTool(.monoline, color: ink.color, width: lineWidth.canvasWidth)
    }
}

private struct MarkupCanvas: UIViewRepresentable {
    let container: MarkupCanvasContainerView

    func makeUIView(context: Context) -> MarkupCanvasContainerView { container }
    func updateUIView(_ uiView: MarkupCanvasContainerView, context: Context) {}
}

/// Makes the canvas's model the first time it's needed. A view's initialiser runs again whenever
/// its parent updates, so reading files and creating a canvas there would repeat while drawing.
final class MarkupEditorLoader {
    private var isLoaded = false
    private var loaded: MarkupEditorModel?

    /// `nil` if the image can't be read or is too large to mark up.
    func model(for request: Composer.MarkupRequest) -> MarkupEditorModel? {
        if !isLoaded {
            isLoaded = true
            loaded = Self.makeModel(for: request)
        }
        return loaded
    }

    private static func makeModel(for request: Composer.MarkupRequest) -> MarkupEditorModel? {
        guard let size = MarkupStore.pixelSize(at: ReferenceStore.url(for: request.referenceFileName)),
              let geometry = MarkupGeometry(pixelWidth: size.width, pixelHeight: size.height),
              geometry.pixelCount <= MarkupStore.maxPixels else { return nil }
        let drawing = request.existingOverlayFileName.flatMap(MarkupStore.loadDrawing(forOverlay:))
        return MarkupEditorModel(geometry: geometry, drawing: drawing,
                                 couldNotRestore: request.existingOverlayFileName != nil && drawing == nil)
    }
}

/// Full-screen canvas for drawing on a reference image.
struct MarkupEditorView: View {
    let request: Composer.MarkupRequest

    @Environment(Composer.self) private var composer
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var loader = MarkupEditorLoader()
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showingDiscardConfirmation = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Read in the body rather than in a task, as the canvas needs it to lay out at all.
            if let model = loader.model(for: request) {
                editor(model)
            } else {
                unavailable
            }
        }
        .environment(\.colorScheme, .dark)
        .alert("Couldn't Save Markup", isPresented: showingSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func editor(_ model: MarkupEditorModel) -> some View {
        VStack(spacing: 10) {
            if verticalSizeClass == .compact {
                // A landscape phone has no height to spare, so everything shares one row.
                HStack(spacing: 6) {
                    cancelButton(model)
                    Spacer(minLength: 0)
                    historyButtons(model)
                    Spacer(minLength: 0)
                    toolButtons(model)
                    Spacer(minLength: 0)
                    doneButton(model)
                }
            } else {
                HStack(spacing: 6) {
                    cancelButton(model)
                    Spacer(minLength: 0)
                    historyButtons(model)
                    Spacer(minLength: 0)
                    doneButton(model)
                }
            }

            MarkupCanvas(container: model.container)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if model.couldNotRestore, !model.hasChanges {
                        Label("The earlier drawing can't be edited. Drawing here replaces it.", systemImage: "exclamationmark.circle")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                    }
                }

            if verticalSizeClass != .compact {
                HStack(spacing: 6) {
                    toolButtons(model)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(isSaving)
        .overlay { if isSaving { ProgressView().controlSize(.large) } }
        .task {
            let url = ReferenceStore.url(for: request.referenceFileName)
            model.container.imageView.image = await ImageLoader.shared.image(at: url, maxPixelSize: ReferenceStore.maxPixelSize)
        }
        .confirmationDialog("Discard your changes to this markup?", isPresented: $showingDiscardConfirmation,
                            titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { composer.cancelMarkup(request) }
            Button("Keep Drawing", role: .cancel) {}
        }
    }

    private var unavailable: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("This image can't be marked up.")
            Button("Close") { composer.cancelMarkup(request) }
                .buttonStyle(.glass)
        }
    }

    private func cancelButton(_ model: MarkupEditorModel) -> some View {
        Button("Cancel") {
            if model.hasChanges {
                showingDiscardConfirmation = true
            } else {
                composer.cancelMarkup(request)
            }
        }
        .buttonStyle(.glass)
    }

    private func doneButton(_ model: MarkupEditorModel) -> some View {
        Button {
            isSaving = true
            Task {
                do {
                    let overlay = try await model.save(existingOverlay: request.existingOverlayFileName)
                    composer.finishMarkup(request, overlay: overlay)
                } catch {
                    saveError = error.localizedDescription
                }
                isSaving = false
            }
        } label: {
            Text("Done")
                .fontWeight(.semibold)
                .foregroundStyle(.black)
        }
        .buttonStyle(.glassProminent)
        .tint(.white)
    }

    @ViewBuilder
    private func historyButtons(_ model: MarkupEditorModel) -> some View {
        iconButton("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
            .disabled(!model.history.canUndo)
        iconButton("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
            .disabled(!model.history.canRedo)
        iconButton("Clear", systemImage: "trash") { model.clear() }
            .disabled(model.isEmpty)
    }

    @ViewBuilder
    private func toolButtons(_ model: MarkupEditorModel) -> some View {
        ForEach(MarkupInk.allCases) { ink in
            toolButton(ink.accessibilityName, isSelected: !model.isErasing && model.ink == ink) {
                model.ink = ink
            } label: {
                Circle().fill(Color(ink.color)).frame(width: 22, height: 22)
            }
        }
        Spacer(minLength: 0)
        ForEach(MarkupLineWidth.allCases) { width in
            toolButton(width.accessibilityName, isSelected: !model.isErasing && model.lineWidth == width) {
                model.lineWidth = width
            } label: {
                Circle().fill(.white).frame(width: width.dotSize, height: width.dotSize)
            }
        }
        Spacer(minLength: 0)
        toolButton("Eraser", isSelected: model.isErasing) {
            model.isErasing = true
        } label: {
            Image(systemName: "eraser").foregroundStyle(.white)
        }
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(title)
    }

    private func toolButton(_ title: String, isSelected: Bool, action: @escaping () -> Void,
                            @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            label()
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.white.opacity(0.22) : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var showingSaveError: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }
}
