import SwiftUI
import UIKit

/// What's known about a failed generation: each attempt and what the server said.
struct GenerationFailureView: View {
    let job: Studio.Job

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                if case .failed(let message) = job.state {
                    Section("Error") { Text(message) }
                }
                if job.attemptLog.isEmpty {
                    Section {
                        Text("No request details were recorded for this failure.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(job.attemptLog) { attempt in
                    Section("Attempt \(attempt.attempt)") {
                        rows(GenerationFailureReport.attemptRows(attempt))
                    }
                }
                Section("Request") {
                    rows(GenerationFailureReport.requestRows(settings: job.settings, referenceCount: job.references.count,
                                                             hasMarkup: job.markupFileName != nil))
                    row("Prompt", job.prompt)
                }
                Section {
                    Button(copied ? "Copied" : "Copy Details", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = report
                        copied = true
                    }
                } footer: {
                    Text("Includes the prompt and request IDs, never your API key.")
                }
            }
            .navigationTitle("Failure Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func rows(_ rows: [(String, String)]) -> some View {
        ForEach(rows, id: \.0) { label, value in row(label, value) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var report: String {
        var message: String?
        if case .failed(let text) = job.state { message = text }
        return GenerationFailureReport.text(prompt: job.prompt, settings: job.settings, referenceCount: job.references.count,
                                            hasMarkup: job.markupFileName != nil, message: message, attempts: job.attemptLog)
    }
}
