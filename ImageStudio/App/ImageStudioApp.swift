import SwiftData
import SwiftUI

@main
struct ImageStudioApp: App {
    private let container: ModelContainer
    @State private var apiKeys: APIKeyStore
    @State private var preferences = Preferences()
    @State private var composer = Composer()
    @State private var studio: Studio

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: GeneratedImage.self)
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
