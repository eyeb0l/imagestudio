import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(Studio.self) private var studio
    @Environment(Composer.self) private var composer
    @Environment(\.dismiss) private var dismiss

    @Query private var images: [GeneratedImage]
    @State private var showingDeleteAll = false

    var body: some View {
        @Bindable var preferences = preferences

        NavigationStack {
            Form {
                APIKeySection()

                GenerationOptionsForm(settings: $preferences.defaults, header: "Defaults for New Images")

                Section("Library") {
                    LabeledContent("Images", value: images.count.formatted())
                    LabeledContent("Storage", value: storageUsed)
                    Button("Delete All Images", role: .destructive) { showingDeleteAll = true }
                        .disabled(images.isEmpty)
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } footer: {
                    Text("Images are generated with the OpenAI Image API and billed to your OpenAI account.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .confirmationDialog(
                "All \(images.count) images will be permanently deleted.",
                isPresented: $showingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All Images", role: .destructive) { studio.deleteAll(keeping: composer.heldFileNames) }
            }
        }
    }

    private var storageUsed: String {
        Int64(images.reduce(0) { $0 + $1.fileSize }).formatted(.byteCount(style: .file))
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - API key

private struct APIKeySection: View {
    @Environment(APIKeyStore.self) private var apiKeys

    @State private var draft = ""
    @State private var isReplacing = false
    @State private var isVerifying = false
    @State private var message: Message?
    @State private var showingRemoveConfirmation = false
    @FocusState private var fieldFocused: Bool

    private enum Message {
        case error(String)
        case warning(String)
    }

    var body: some View {
        Section {
            if apiKeys.isConfigured && !isReplacing {
                LabeledContent("API Key") {
                    Text(apiKeys.maskedKey ?? "")
                        .font(.body.monospaced())
                }
                Button("Replace Key") {
                    message = nil
                    isReplacing = true
                    fieldFocused = true
                }
                Button("Remove Key", role: .destructive) { showingRemoveConfirmation = true }
            } else if let readError = apiKeys.readError, !isReplacing {
                // A key may well be stored; don't present this as if there were none.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't read the saved key")
                    Text(readError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Try Again") { apiKeys.reload() }
                Button("Enter a New Key") {
                    message = nil
                    isReplacing = true
                    fieldFocused = true
                }
            } else {
                SecureField("sk-…", text: $draft)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }

                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Text(isVerifying ? "Verifying…" : "Save Key")
                        if isVerifying {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(trimmedDraft.isEmpty || isVerifying)

                if isReplacing {
                    Button("Cancel") {
                        draft = ""
                        message = nil
                        isReplacing = false
                    }
                }
            }
        } header: {
            Text("OpenAI API Key")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                switch message {
                case .error(let text): Text(text).foregroundStyle(.red)
                case .warning(let text): Text(text).foregroundStyle(.orange)
                case nil: EmptyView()
                }
                Text("Stored in the Keychain on this device only. It's never synced or backed up, and is sent only to OpenAI. [Create a key](https://platform.openai.com/api-keys)")
            }
        }
        .confirmationDialog("Remove your API key from this device?", isPresented: $showingRemoveConfirmation,
                            titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                do {
                    try apiKeys.remove()
                    message = nil
                } catch {
                    message = .error("Couldn't remove the key from the Keychain: \(error.localizedDescription)")
                }
            }
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        let key = trimmedDraft
        guard !key.isEmpty, !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }

        do {
            try await OpenAIImageClient.shared.verify(apiKey: key)
            message = nil
        } catch OpenAIError.invalidAPIKey {
            message = .error("OpenAI didn't accept this key. Check that it's copied correctly and still active.")
            return
        } catch {
            // Couldn't reach OpenAI (e.g. offline); keep the key but say it's unverified.
            message = .warning("Saved, but the key couldn't be verified: \(error.localizedDescription)")
        }

        do {
            try apiKeys.save(key)
            draft = ""
            isReplacing = false
            fieldFocused = false
        } catch {
            message = .error("Couldn't save to the Keychain: \(error.localizedDescription)")
        }
    }
}
