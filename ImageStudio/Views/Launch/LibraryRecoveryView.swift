import SwiftUI

/// Shown instead of the app when the library database can't be opened.
struct LibraryRecoveryView: View {
    let model: AppModel
    @State private var showingResetConfirmation = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
            Text("Library Couldn't Be Opened")
                .font(.system(.title2, design: .serif))
                .multilineTextAlignment(.center)
            Text("Your image files are safe. Try again, or reset the library to start with a fresh one. A backup of the current library is kept.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let failure = model.openFailure {
                DisclosureGroup("Details") {
                    Text(failure)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }

            if let resetFailure = model.resetFailure {
                Text(resetFailure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button("Try Again", action: model.retry)
                    .buttonStyle(.glass)
                Button("Reset Library…", role: .destructive) { showingResetConfirmation = true }
                    .font(.subheadline)
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: 480, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .confirmationDialog("Reset the library?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("Reset Library", role: .destructive) { model.resetLibrary() }
        } message: {
            Text("The current library is moved to a backup in Library Backups and a new, empty one is created. Your image files stay where they are.")
        }
    }
}
