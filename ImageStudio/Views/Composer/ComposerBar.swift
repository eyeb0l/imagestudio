import PhotosUI
import SwiftUI

/// The floating prompt box: a prompt field, the active settings as tappable chips, and a send button.
struct ComposerBar: View {
    @Environment(Composer.self) private var composer
    @Environment(Preferences.self) private var preferences

    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    @State private var showingOptions = false
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var composer = composer
        let settings = composer.settings(defaults: preferences.defaults)
        let defaults = preferences.defaults.normalized()

        let hasReferences = !composer.references.isEmpty || composer.importingCount > 0

        VStack(alignment: .leading, spacing: 10) {
            if hasReferences {
                ReferenceStrip()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            TextField(hasReferences ? "Describe what to make with these images…" : "Describe an image…",
                      text: $composer.prompt, axis: .vertical)
                .lineLimit(1...6)
                .focused(isFocused)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 8) {
                attachButton

                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        chips(settings: settings, defaults: defaults)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
                .scrollIndicators(.hidden)
                .clipShape(.capsule)

                sendButton
            }
        }
        .padding(10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .sheet(isPresented: $showingOptions) { ComposerOptionsSheet() }
        .animation(.snappy, value: hasReferences)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                await composer.addReferences(items.map { item in
                    { try await item.loadTransferable(type: Data.self) }
                })
            }
        }
    }

    private var attachButton: some View {
        let hasReferences = !composer.references.isEmpty
        return PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: max(composer.remainingReferenceSlots, 1),
            selectionBehavior: .ordered,
            matching: .images,
            photoLibrary: .shared()
        ) {
            OptionChip(systemImage: "photo.badge.plus", isModified: hasReferences)
        }
        .buttonStyle(.plain)
        .disabled(composer.remainingReferenceSlots == 0)
        .accessibilityLabel("Add Reference Images")
    }

    @ViewBuilder
    private func chips(settings: GenerationSettings, defaults: GenerationSettings) -> some View {
        Menu {
            Picker("Model", selection: binding(\.model)) {
                ForEach(ImageModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
        } label: {
            OptionChip(title: settings.model.shortName, isModified: settings.model != defaults.model)
        }
        .accessibilityLabel("Model, \(settings.model.displayName)")

        Menu {
            Picker("Size", selection: binding(\.size)) {
                ForEach(sizeOptions(for: settings)) { size in
                    Text(size.isAuto ? "Auto" : "\(size.title)  \(size.dimensionsLabel)").tag(size)
                }
            }
            if settings.model.supportsCustomSizes {
                Button("Custom Size…", systemImage: "square.dashed") { showingOptions = true }
            }
        } label: {
            OptionChip(title: settings.size.shortLabel, systemImage: "aspectratio",
                       isModified: settings.size != defaults.size)
        }
        .accessibilityLabel("Size, \(settings.size.isAuto ? "Auto" : settings.size.dimensionsLabel)")

        Menu {
            Picker("Quality", selection: binding(\.quality)) {
                ForEach(settings.model.supportedQualities) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
        } label: {
            OptionChip(title: settings.quality.displayName, systemImage: "dial.medium",
                       isModified: settings.quality != defaults.quality)
        }
        .accessibilityLabel("Quality, \(settings.quality.displayName)")

        Menu {
            Picker("Images", selection: binding(\.count)) {
                ForEach(GenerationSettings.countRange, id: \.self) { count in
                    Text(count == 1 ? "1 Image" : "\(count) Images").tag(count)
                }
            }
        } label: {
            OptionChip(title: "\(settings.count)", systemImage: "square.stack",
                       isModified: settings.count != defaults.count)
        }
        .accessibilityLabel(settings.count == 1 ? "1 image" : "\(settings.count) images")

        Button { showingOptions = true } label: {
            OptionChip(systemImage: "slider.horizontal.3", isModified: outputDiffers(settings, defaults))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More Options")

        if composer.overrides != nil {
            Button {
                withAnimation(.snappy) { composer.overrides = nil }
            } label: {
                OptionChip(systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset to Defaults")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var sendButton: some View {
        let isEmpty = composer.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || composer.importingCount > 0
        return Button(action: onSubmit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(isEmpty ? .tertiaryLabel : .systemBackground))
                .frame(width: 34, height: 34)
                .background(Color(isEmpty ? .tertiarySystemFill : .label), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
        .animation(.snappy, value: isEmpty)
        .accessibilityLabel("Generate")
    }

    // MARK: Helpers

    private func binding<Value>(_ keyPath: WritableKeyPath<GenerationSettings, Value>) -> Binding<Value> {
        Binding(
            get: { composer.settings(defaults: preferences.defaults)[keyPath: keyPath] },
            set: { newValue in
                var settings = composer.settings(defaults: preferences.defaults)
                settings[keyPath: keyPath] = newValue
                withAnimation(.snappy) { composer.setSettings(settings, defaults: preferences.defaults) }
            }
        )
    }

    private func sizeOptions(for settings: GenerationSettings) -> [ImageSize] {
        let presets = settings.model.sizePresets
        return presets.contains(settings.size) ? presets : presets + [settings.size]
    }

    private func outputDiffers(_ a: GenerationSettings, _ b: GenerationSettings) -> Bool {
        a.background != b.background || a.outputFormat != b.outputFormat
            || a.moderation != b.moderation
            || (a.outputFormat.supportsCompression && a.compression != b.compression)
    }
}

/// A compact capsule showing one setting. Values that differ from the defaults are emphasised.
struct OptionChip: View {
    var title: String?
    var systemImage: String?
    var isModified = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            if let title {
                Text(title).lineLimit(1)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Color(isModified ? .label : .secondaryLabel))
        .padding(.horizontal, title == nil ? 9 : 11)
        .frame(height: 30)
        .background(Color(isModified ? .secondarySystemFill : .tertiarySystemFill), in: .capsule)
        .contentShape(.capsule)
    }
}

/// All options for the next generation, with shortcuts to reset or save them as defaults.
struct ComposerOptionsSheet: View {
    @Environment(Composer.self) private var composer
    @Environment(Preferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                GenerationOptionsForm(settings: settings, header: "Next Generation")
                Section {
                    Button("Save as Defaults") {
                        preferences.defaults = composer.settings(defaults: preferences.defaults)
                        composer.overrides = nil
                    }
                    .disabled(composer.overrides == nil)
                    Button("Reset to Defaults") { composer.overrides = nil }
                        .disabled(composer.overrides == nil)
                } footer: {
                    Text("Changes here apply to images you create from the prompt box. Defaults are set in Settings.")
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var settings: Binding<GenerationSettings> {
        Binding(
            get: { composer.settings(defaults: preferences.defaults) },
            set: { composer.setSettings($0, defaults: preferences.defaults) }
        )
    }
}

/// Attached reference images, shown above the prompt with a remove button on each.
private struct ReferenceStrip: View {
    @Environment(Composer.self) private var composer

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(composer.references, id: \.self) { name in
                    ReferenceThumbnail(fileName: name)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                withAnimation(.snappy) { composer.removeReference(name) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(.black.opacity(0.55), in: .circle)
                                    .padding(4)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove Reference")
                        }
                        .transition(.scale.combined(with: .opacity))
                }
                ForEach(0..<composer.importingCount, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 11)
                        .fill(.fill.tertiary)
                        .frame(width: 56, height: 56)
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}
