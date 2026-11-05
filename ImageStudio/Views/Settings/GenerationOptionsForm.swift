import SwiftUI

/// Form sections for editing generation settings. Used for both defaults and per-generation overrides.
struct GenerationOptionsForm: View {
    @Binding var settings: GenerationSettings
    var header: String = "Generation"
    /// Whether the settings are for a request with reference images, which limits the formats.
    var hasReferences = false
    /// Whether the settings are for a request with markup, which limits the models.
    var hasMarkup = false

    var body: some View {
        Section {
            NavigationLink {
                ModelPickerView(selection: modelBinding, models: ImageModel.available(hasMarkup: hasMarkup))
            } label: {
                LabeledContent("Model", value: settings.model.displayName)
            }

            NavigationLink {
                SizePickerView(settings: $settings)
            } label: {
                LabeledContent("Size", value: settings.size.isAuto ? "Auto" : settings.size.dimensionsLabel)
            }

            Picker("Quality", selection: $settings.quality) {
                ForEach(settings.model.supportedQualities) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }

            if settings.model.supportsComplexity {
                Picker("Complexity", selection: $settings.complexity) {
                    ForEach(ImageComplexity.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Stepper(value: $settings.count, in: settings.allowedCountRange) {
                LabeledContent("Images", value: settings.count.formatted())
            }
            .disabled(!settings.outputFormat.allowsMultipleImages)
        } header: {
            Text(header)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if hasMarkup {
                    Text("Markup works with GPT Image 2.5 and 2.6.")
                }
                if settings.outputFormat == .svg {
                    Text("SVG makes one image per request. Quality and complexity apply to the reference image OpenAI creates first, then a second model writes the SVG.")
                }
                if settings.model.supportsComplexity {
                    Text("Complexity sets how much the model plans before rendering. Higher helps with dense text and complex layouts, but can take longer and introduce unwanted changes.")
                }
            }
        }

        Section {
            Picker("Background", selection: backgroundBinding) {
                ForEach(ImageBackground.allCases) { Text($0.displayName).tag($0) }
            }

            Picker("Format", selection: formatBinding) {
                ForEach(settings.model.formats(hasReferences: hasReferences)) { Text($0.displayName).tag($0) }
            }

            if settings.outputFormat.isVector {
                Picker("SVG Author", selection: $settings.svgAuthor) {
                    ForEach(SVGAuthorModel.allCases) { Text($0.displayName).tag($0) }
                }
            }

            if settings.outputFormat.supportsCompression {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Compression", value: "\(settings.compression)%")
                    Slider(value: compressionBinding, in: 0...100, step: 5)
                }
            }

            Picker("Moderation", selection: $settings.moderation) {
                ForEach(ModerationLevel.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("Output")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Transparent backgrounds need PNG or WebP. Low moderation applies less restrictive content filtering.")
                if let unavailableFormatsNote {
                    Text(unavailableFormatsNote)
                }
            }
        }

        if settings.outputFormat.isAnimated {
            Section {
                Stepper(value: $settings.frameCount, in: GenerationSettings.frameCountRange) {
                    LabeledContent("Frames", value: settings.frameCount.formatted())
                }
                Stepper(value: $settings.frameDurationMs, in: GenerationSettings.frameDurationRange,
                        step: GenerationSettings.frameDurationStep) {
                    LabeledContent("Frame Duration", value: "\(settings.frameDurationMs.formatted()) ms")
                }
            } header: {
                Text("Animation")
            } footer: {
                Text("Each loop lasts \(loopSeconds) s. If a request is too large, reduce the frames, size or number of images.")
            }
        }
    }

    /// Says which of the model's formats reference images rule out, if any.
    private var unavailableFormatsNote: String? {
        guard hasReferences else { return nil }
        let unavailable = settings.model.supportedFormats.filter { !settings.model.formats(hasReferences: true).contains($0) }
        guard !unavailable.isEmpty else { return nil }
        return "\(unavailable.map(\.displayName).formatted(.list(type: .or))) can't be used with reference images."
    }

    private var loopSeconds: String {
        (Double(settings.frameCount * settings.frameDurationMs) / 1000).formatted(.number.precision(.fractionLength(0...2)))
    }

    // Bindings that keep combinations valid.

    private var modelBinding: Binding<ImageModel> {
        Binding(get: { settings.model }, set: { model in
            var updated = settings
            updated.model = model
            settings = updated.normalized(hasReferences: hasReferences, hasMarkup: hasMarkup)
        })
    }

    private var backgroundBinding: Binding<ImageBackground> {
        Binding(get: { settings.background }, set: { background in
            var updated = settings
            updated.background = background
            settings = updated.normalized(hasReferences: hasReferences, hasMarkup: hasMarkup)
        })
    }

    private var formatBinding: Binding<OutputFormat> {
        Binding(get: { settings.outputFormat }, set: { format in
            var updated = settings
            updated.outputFormat = format
            if !format.supportsTransparency, updated.background == .transparent {
                updated.background = .auto
            }
            settings = updated.normalized(hasReferences: hasReferences, hasMarkup: hasMarkup)
        })
    }

    private var compressionBinding: Binding<Double> {
        Binding(get: { Double(settings.compression) }, set: { settings.compression = Int($0) })
    }
}

// MARK: - Model picker

struct ModelPickerView: View {
    @Binding var selection: ImageModel
    var models = ImageModel.allCases
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(models) { model in
            Button {
                selection = model
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.displayName)
                            .foregroundStyle(.primary)
                        Text(model.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model == selection {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Size picker

struct SizePickerView: View {
    @Binding var settings: GenerationSettings
    /// Opened just to enter a custom size, so that's all it shows, ready to type in.
    var showsOnlyCustomSize = false
    /// Called when a custom size is chosen, for a sheet that was opened just to do that.
    var onCustomSizeChosen: () -> Void = {}

    @State private var customWidth = ""
    @State private var customHeight = ""
    private enum CustomField { case width, height }
    @FocusState private var focusedField: CustomField?

    var body: some View {
        List {
            if showsOnlyCustomSize {
                customSection
            } else {
                Section {
                    ForEach(ImageSize.standardPresets) { row(for: $0) }
                } footer: {
                    if !settings.model.supportsCustomSizes {
                        Text("Larger and custom sizes are available with GPT Image 2 and later.")
                    }
                }

                if settings.model.supportsCustomSizes {
                    Section {
                        ForEach(ImageSize.extendedPresets) { row(for: $0) }
                    } header: {
                        Text("More Sizes")
                    } footer: {
                        Text("Sizes above 2560 × 1440 are experimental.")
                    }

                    customSection
                }
            }
        }
        .navigationTitle(showsOnlyCustomSize ? "Custom Size" : "Size")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let isPreset = settings.model.sizePresets.contains(settings.size)
            if !settings.size.isAuto, !isPreset {
                customWidth = String(settings.size.width)
                customHeight = String(settings.size.height)
            }
            if showsOnlyCustomSize { focusedField = .width }
        }
    }

    private func row(for size: ImageSize) -> some View {
        Button {
            settings.size = size
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(size.title).foregroundStyle(.primary)
                    Text(size.isExperimental ? "\(size.dimensionsLabel) · Experimental" : size.dimensionsLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let tag = size.resolutionTag {
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.tertiary, in: .capsule)
                }
                if size == settings.size {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var customSection: some View {
        let width = Int(customWidth) ?? 0
        let height = Int(customHeight) ?? 0
        let hasInput = !customWidth.isEmpty || !customHeight.isEmpty
        let message = ImageSize.validationMessage(width: width, height: height)
        let candidate = ImageSize(width: width, height: height)

        return Section {
            HStack {
                TextField("Width", text: $customWidth)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .width)
                Text("×").foregroundStyle(.secondary)
                TextField("Height", text: $customHeight)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .height)
                    .multilineTextAlignment(.trailing)
            }
            .font(.body.monospacedDigit())

            Button(settings.size == candidate ? "Using Custom Size" : "Use Custom Size") {
                settings.size = candidate
                focusedField = nil
                onCustomSizeChosen()
            }
            .disabled(message != nil || settings.size == candidate)
        } header: {
            Text("Custom")
        } footer: {
            if hasInput, let message {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Multiples of 16, up to 3840 px per side, with an aspect ratio between 1:3 and 3:1.")
            }
        }
    }
}
