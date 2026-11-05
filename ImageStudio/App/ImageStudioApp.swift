import SwiftData
import SwiftUI
import UIKit

@main
struct ImageStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Created during app init (not when the first view appears) so that `Studio` reconnects to
    /// `GenerationSession` and saves results after a background relaunch, with or without UI.
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before launch finishes, so a tap on a notification that launches the app is delivered.
        GenerationNotifier.shared.activate()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            switch model.state {
            case .ready(let services):
                LibraryView()
                    .environment(services.apiKeys)
                    .environment(services.preferences)
                    .environment(services.composer)
                    .environment(services.studio)
                    .environment(GenerationNotifier.shared)
                    .modelContainer(services.container)
            case .recovery:
                LibraryRecoveryView(model: model)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, case .ready(let services) = model.state else { return }
            services.updates.appBecameActive()
        }
    }
}

// MARK: - Launch state

/// Owns the app's long-lived objects. They only exist once the library database has opened;
/// if it can't be opened, `state` is `.recovery` and the user chooses what to do.
@Observable
final class AppModel {
    struct Services {
        let container: ModelContainer
        let apiKeys: APIKeyStore
        let preferences: Preferences
        let composer: Composer
        let studio: Studio
        let updates: GenerationUpdates
    }

    enum State {
        case ready(Services)
        case recovery
    }

    private(set) var state: State = .recovery
    /// What went wrong the last time the library failed to open.
    private(set) var openFailure: String?
    /// Set when moving the library to a backup failed.
    private(set) var resetFailure: String?

    @ObservationIgnored private let opener: @MainActor () throws -> ModelContainer
    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let backupsDirectory: URL
    @ObservationIgnored private let rasterCache: SVGRasterCache
    @ObservationIgnored private var simulatesFailure: Bool

    init(simulatesFailure: Bool = AppModel.launchRequestsSimulatedFailure,
         storeURL: URL = LibraryStore.defaultStoreURL,
         backupsDirectory: URL = LibraryStore.backupsDirectory,
         rasterCache: SVGRasterCache = .shared,
         opener: @escaping @MainActor () throws -> ModelContainer = LibraryStore.open) {
        self.simulatesFailure = simulatesFailure
        self.storeURL = storeURL
        self.backupsDirectory = backupsDirectory
        self.rasterCache = rasterCache
        self.opener = opener
        tryOpen()
    }

    /// Tries to open the library again, e.g. after a transient failure.
    func retry() {
        resetFailure = nil
        tryOpen()
    }

    /// Moves the current store files into a timestamped folder under Library Backups (never
    /// deleting them), then opens a fresh library. Image files are left where they are.
    func resetLibrary(date: Date = .now) {
        do {
            try LibraryStore.moveStoreFiles(from: storeURL, to: backupsDirectory, date: date)
        } catch {
            resetFailure = "The library couldn't be moved to a backup, so nothing was changed. \(error.localizedDescription)"
            return
        }
        // Images in the new library are rendered afresh when they're next shown.
        rasterCache.removeAll()
        resetFailure = nil
        simulatesFailure = false
        tryOpen()
    }

    private func tryOpen() {
        do {
            state = .ready(try makeServices(container: open()))
            openFailure = nil
        } catch {
            state = .recovery
            openFailure = Self.describe(error)
        }
    }

    private func open() throws -> ModelContainer {
        #if DEBUG
        if simulatesFailure { throw LibraryStore.SimulatedFailure() }
        #endif
        return try opener()
    }

    private func makeServices(container: ModelContainer) -> Services {
        let apiKeys = APIKeyStore()
        let studio = Studio(container: container, apiKeys: apiKeys)
        let updates = GenerationUpdates()
        studio.observer = updates

        #if DEBUG
        SampleLibrary.seedIfRequested(context: container.mainContext, studio: studio)
        #endif

        return Services(container: container, apiKeys: apiKeys, preferences: Preferences(),
                        composer: Composer(), studio: studio, updates: updates)
    }

    private static func describe(_ error: Error) -> String {
        let summary = error.localizedDescription
        let technical = String(describing: error)
        return summary == technical ? summary : "\(summary)\n\(technical)"
    }

    /// DEBUG only: `-SimulateLibraryOpenFailure` makes opening fail until the library is reset.
    static var launchRequestsSimulatedFailure: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-SimulateLibraryOpenFailure")
        #else
        false
        #endif
    }
}

// MARK: - Store

enum LibraryStore {
    #if DEBUG
    struct SimulatedFailure: LocalizedError {
        var errorDescription: String? { "Simulated failure (-SimulateLibraryOpenFailure)." }
    }
    #endif

    private static var configuration: ModelConfiguration {
        ModelConfiguration(for: GeneratedImage.self, PendingGeneration.self)
    }

    static func open() throws -> ModelContainer {
        try ModelContainer(for: GeneratedImage.self, PendingGeneration.self, configurations: configuration)
    }

    /// Where SwiftData keeps the library by default (`default.store` in Application Support).
    static var defaultStoreURL: URL { configuration.url }

    static var backupsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Library Backups", directoryHint: .isDirectory)
    }

    /// Moves a SwiftData store and its `-shm` / `-wal` companions into a new
    /// `<backupsDirectory>/<timestamp>` folder. Files are moved, never deleted. If any move
    /// fails, the ones already moved are put back. Returns the folder, or `nil` when there
    /// was nothing to move.
    @discardableResult
    nonisolated static func moveStoreFiles(from storeURL: URL, to backupsDirectory: URL, date: Date = .now,
                                           fileManager: FileManager = .default) throws -> URL? {
        let sources = ["", "-shm", "-wal"]
            .map { storeURL.deletingLastPathComponent().appending(path: storeURL.lastPathComponent + $0) }
            .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !sources.isEmpty else { return nil }

        let backup = uniqueFolder(in: backupsDirectory, date: date, fileManager: fileManager)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)

        var moved: [(from: URL, to: URL)] = []
        do {
            for source in sources {
                let destination = backup.appending(path: source.lastPathComponent)
                try fileManager.moveItem(at: source, to: destination)
                moved.append((source, destination))
            }
        } catch {
            for entry in moved.reversed() { try? fileManager.moveItem(at: entry.to, to: entry.from) }
            try? fileManager.removeItem(at: backup)
            throw error
        }
        return backup
    }

    private nonisolated static func uniqueFolder(in directory: URL, date: Date, fileManager: FileManager) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = formatter.string(from: date)
        var candidate = directory.appending(path: name, directoryHint: .isDirectory)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(name)-\(counter)", directoryHint: .isDirectory)
            counter += 1
        }
        return candidate
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
