import SwiftData
import SwiftUI
import UIKit

@main
struct ImageStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var apiKeys: APIKeyStore
    @State private var preferences = Preferences()
    @State private var composer = Composer()
    @State private var studio: Studio

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: GeneratedImage.self, PendingGeneration.self)
        } catch {
            fatalError("Couldn't open the image library: \(error)")
        }
        let apiKeys = APIKeyStore()
        let studio = Studio(container: container, apiKeys: apiKeys)

        #if DEBUG
        SampleLibrary.seedIfRequested(context: container.mainContext, studio: studio)
        #endif

        self.container = container
        _apiKeys = State(initialValue: apiKeys)
        _studio = State(initialValue: studio)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(apiKeys)
                .environment(preferences)
                .environment(composer)
                .environment(studio)
        }
        .modelContainer(container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Called when the system relaunches the app in the background because generation
    /// requests finished while it wasn't running. The session reconnects when `Studio` is
    /// created; this hands over the handler that tells the system we're done.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == GenerationSession.identifier else {
            completionHandler()
            return
        }
        nonisolated(unsafe) let completion = completionHandler
        GenerationSession.shared.setBackgroundCompletionHandler {
            Task { @MainActor in completion() }
        }
    }
}
