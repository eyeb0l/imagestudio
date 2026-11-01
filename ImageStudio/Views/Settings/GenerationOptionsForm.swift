import SwiftUI

/// Form sections for editing generation settings. Used for both defaults and per-generation overrides.
struct GenerationOptionsForm: View {
    @Binding var settings: GenerationSettings
    var header: String = "Generation"

    var body: some View {
        Section(header) {
            NavigationLink {
                ModelPickerView(selection: modelBinding)
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

            Stepper(value: $settings.count, in: GenerationSettings.countRange) {
                LabeledContent("Images", value: settings.count.formatted())
            }
        }

        Section {
            Picker("Background", selection: backgroundBinding) {
                ForEach(ImageBackground.allCases) { Text($0.displayName).tag($0) }
            }

            Picker("Format", selection: formatBinding) {
                ForEach(OutputFormat.allCases) { Text($0.displayName).tag($0) }
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
            Text("Transparent backgrounds need PNG or WebP. Low moderation applies less restrictive content filtering.")
        }
    }

    // Bindings that keep combinations valid.

    private var modelBinding: Binding<ImageModel> {
        Binding(get: { settings.model }, set: { model in
            var updated = settings
            updated.model = model
            settings = updated.normalized()
        })
    }

    private var backgroundBinding: Binding<ImageBackground> {
        Binding(get: { settings.background }, set: { background in
            settings.background = background
            if background == .transparent, !settings.outputFormat.supportsTransparency {
                settings.outputFormat = .png
            }
        })
    }

    private var formatBinding: Binding<OutputFormat> {
        Binding(get: { settings.outputFormat }, set: { format in
            settings.outputFormat = format
            if !format.supportsTransparency, settings.background == .transparent {
                settings.background = .auto
            }
        })
    }

    private var compressionBinding: Binding<Double> {
        Binding(get: { Double(settings.compression) }, set: { settings.compression = Int($0) })
    }
}

// MARK: - Model picker

struct ModelPickerView: View {
    @Binding var selection: ImageModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(ImageModel.allCases) { model in
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

    @State private var customWidth = ""
    @State private var customHeight = ""
    @FocusState private var customFocused: Bool

    var body: some View {
        List {
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
        .navigationTitle("Size")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let isPreset = settings.model.sizePresets.contains(settings.size)
            if !settings.size.isAuto, !isPreset {
                customWidth = String(settings.size.width)
                customHeight = String(settings.size.height)
            }
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
                    .focused($customFocused)
                Text("×").foregroundStyle(.secondary)
                TextField("Height", text: $customHeight)
                    .keyboardType(.numberPad)
                    .focused($customFocused)
                    .multilineTextAlignment(.trailing)
            }
            .font(.body.monospacedDigit())

            Button(settings.size == candidate ? "Using Custom Size" : "Use Custom Size") {
                settings.size = candidate
                customFocused = false
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
