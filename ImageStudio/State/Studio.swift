import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

/// Runs generation requests and owns library mutations (insert, delete).
///
/// Requests run on `GenerationSession`'s background URLSession, so they keep going while the
/// app is suspended. Jobs are mirrored to `PendingGeneration` records so their tiles survive
/// the app being closed; results are matched back to jobs by ID whenever they arrive.
///
/// Transient failures (rate limits, 5xx, flaky connections) are retried automatically, up to
/// `RetryPolicy.maxAttempts` attempts in total. A retry is a new background task with an earliest
/// start date, so it fires even if the app is suspended in the meantime.
@Observable
final class Studio {
    struct Job: Identifiable, Equatable {
        enum State: Equatable {
            case running
            case failed(String)
        }

        let id: UUID
        let prompt: String
        let settings: GenerationSettings
        var startedAt: Date
        var state: State
        /// Which request attempt this is (1-based). Failed requests that are worth retrying are
        /// retried automatically while the job stays `.running`.
        var attempt: Int
        /// Reference images (in `ReferenceStore`) sent with the request.
        let references: [String]
        /// The annotation layer (see `MarkupStore`) for the first reference, if any.
        let markupFileName: String?
        /// The failed attempts so far, and what the server said.
        var attemptLog: [GenerationAttemptLog] = []

        init(id: UUID = UUID(), prompt: String, settings: GenerationSettings,
             startedAt: Date = .now, state: State = .running, attempt: Int = 1, references: [String] = [],
             markupFileName: String? = nil) {
            self.id = id
            self.references = references
            self.markupFileName = markupFileName
            self.prompt = prompt
            self.settings = settings
            self.startedAt = startedAt
            self.state = state
            self.attempt = attempt
        }

        var isFailed: Bool {
            if case .failed = state { true } else { false }
        }

        /// Every file in `ReferenceStore` this job relies on.
        var referenceStoreFileNames: [String] {
            references + MarkupStore.fileNames(forOverlay: markupFileName)
        }
    }

    /// In-flight and failed generations, shown as placeholder tiles in the library.
    private(set) var jobs: [Job] = [] {
        didSet { if jobs != oldValue { observer?.jobsChanged(jobs) } }
    }
    /// Shows generations outside the app (Live Activity, notifications).
    @ObservationIgnored var observer: (any GenerationObserver)? {
        didSet { observer?.jobsChanged(jobs) }
    }
    /// Told about images added to or deleted from the library on this device (iCloud sync).
    /// Changes that arrive from iCloud aren't passed back to it.
    @ObservationIgnored weak var libraryObserver: (any LibraryObserver)?
    /// Incremented on each success / failure; drives haptics.
    private(set) var completedCount = 0
    private(set) var failureCount = 0
    /// A library-level error to show the user (e.g. a failed delete). Cleared when dismissed.
    var alertMessage: String?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let apiKeys: APIKeyStore
    @ObservationIgnored private let session: GenerationSession
    /// Downloaded results whose save failed, kept so Retry can save them again without paying for
    /// a new request. In memory only: they last until the job is removed or the app quits.
    @ObservationIgnored private var heldOutputs: [Job.ID: (ticket: GenerationTicket, output: OpenAIImageClient.Output)] = [:]
    /// Removes files in `ReferenceStore` other than the ones given.
    @ObservationIgnored private let removeOrphanedReferences: (Set<String>) -> Void

    private static let log = Logger(subsystem: "com.eyeb0l.ImageStudio", category: "Studio")

    private var context: ModelContext { container.mainContext }

    static let interruptedMessage = "Image Studio was closed before this image finished. Retry to generate it again."

    init(container: ModelContainer, apiKeys: APIKeyStore, session: GenerationSession = .shared,
         removeOrphanedReferences: @escaping (Set<String>) -> Void = { ReferenceStore.removeOrphans(keeping: $0) }) {
        self.container = container
        self.apiKeys = apiKeys
        self.session = session
        self.removeOrphanedReferences = removeOrphanedReferences

        let records: [PendingGeneration]
        do {
            records = try container.mainContext.fetch(
                FetchDescriptor<PendingGeneration>(sortBy: [SortDescriptor(\.startedAt)])
            )
        } catch {
            Self.log.error("Couldn't load pending generations: \(error.localizedDescription, privacy: .public)")
            records = []
        }
        jobs = records.map { record in
            var job = Job(id: record.id, prompt: record.prompt, settings: record.settings, startedAt: record.startedAt,
                          state: record.failureMessage.map { .failed($0) } ?? .running, attempt: record.attempt,
                          references: record.referenceFileNames, markupFileName: record.markupFileName)
            job.attemptLog = record.attemptLog
            return job
        }

        // Nothing else holds references at launch (the composer starts empty), so any file not
        // used by an image or a job is left over, e.g. from an attachment that was never sent.
        removeOrphanedReferences(referencedFileNames())

        session.setResultHandler { [weak self] ticket, outcome, retryAfter, attemptLog in
            await self?.handle(ticket, outcome, retryAfter: retryAfter, attemptLog: attemptLog)
        }

        let restoredRunning = jobs.filter { !$0.isFailed }.map(\.id)
        if !restoredRunning.isEmpty {
            Task { await reconcile(restoredRunning) }
        }
    }

    // MARK: Generation

    /// Starts a generation. With `references` (file names in `ReferenceStore`), the request uses
    /// them as reference images, with `markup` (see `MarkupStore`) as an annotation layer for the
    /// first one; the job takes ownership of those files.
    func generate(prompt: String, settings: GenerationSettings, references: [String] = [], markup: String? = nil) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let job = Job(prompt: prompt,
                      settings: settings.normalized(hasReferences: !references.isEmpty, hasMarkup: markup != nil),
                      references: references, markupFileName: markup)
        withAnimation(.snappy) { jobs.append(job) }
        context.insert(PendingGeneration(id: job.id, prompt: job.prompt, settings: job.settings,
                                         startedAt: job.startedAt, referenceFileNames: job.references,
                                         markupFileName: job.markupFileName))
        // If this fails the request still runs and its images are still saved; only the
        // placeholder tile wouldn't survive a relaunch. The record is retried on the next save.
        saveContext("record pending generation")
        observer?.generationStarted()
        start(job)
    }

    /// Generates one new image per source image, using the same prompt and settings.
    func regenerate(_ images: [GeneratedImage]) {
        for image in images {
            generate(prompt: image.prompt, settings: image.settings, references: image.referenceFileNames,
                     markup: image.markupFileName)
        }
    }

    func retry(_ job: Job) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].state = .running
        if let held = heldOutputs[job.id] {
            // The image was generated (and paid for); only saving it failed. Save it again.
            updateRecord(jobs[index])
            Task { await finish(held.output, for: held.ticket) }
            return
        }
        jobs[index].startedAt = .now
        jobs[index].attempt = 1
        updateRecord(jobs[index])
        start(jobs[index])
    }

    /// Cancels a running job, or dismisses a failed one.
    func cancel(_ job: Job) {
        removeJob(job.id)
        Task { await session.cancel(jobID: job.id) }
    }

    private func start(_ job: Job) {
        let ticket = GenerationTicket(jobID: job.id, prompt: job.prompt, settings: job.settings,
                                      startedAt: job.startedAt, attempt: job.attempt,
                                      referenceFileNames: job.references, markupFileName: job.markupFileName)
        if let problem = submit(ticket) {
            markFailed(job.id, message: problem)
        }
    }

    /// Hands a request to the background session, reading the API key afresh each time (a retry
    /// may happen long after the first attempt). Returns a description of what went wrong, if anything.
    private func submit(_ ticket: GenerationTicket, notBefore: Date? = nil) -> String? {
        let apiKey: String
        do {
            guard let key = try apiKeys.loadKey() else { return OpenAIError.missingAPIKey.localizedDescription }
            apiKey = key
        } catch {
            return "Couldn't read your API key from the Keychain: \(error.localizedDescription)"
        }
        do {
            try session.start(ticket, apiKey: apiKey, notBefore: notBefore)
            return nil
        } catch {
            return "Couldn't start the request: \(error.localizedDescription)"
        }
    }

    /// Called for every finished request — including ones started before the app was relaunched.
    private func handle(_ ticket: GenerationTicket, _ outcome: GenerationSession.Outcome,
                        retryAfter: TimeInterval?, attemptLog: GenerationAttemptLog?) async {
        switch outcome {
        case .success(let output):
            await finish(output, for: ticket)
        case .failure(let error):
            // No job means the user cancelled or dismissed it; nothing to report.
            guard jobs.contains(where: { $0.id == ticket.jobID }) else { return }
            handleFailure(error, for: ticket, retryAfter: retryAfter, attemptLog: attemptLog)
        }
        // After a background relaunch the app may be suspended once this returns, so make sure the
        // Live Activity update and notification have gone out.
        await observer?.settle()
    }

    private func handleFailure(_ error: any Error, for ticket: GenerationTicket, retryAfter: TimeInterval?,
                               attemptLog: GenerationAttemptLog?) {
        var message = Self.message(for: error, settings: ticket.settings)
        record(attemptLog, message: message, jobID: ticket.jobID)

        if let delay = RetryPolicy.retryDelay(after: error, attempt: ticket.attempt, format: ticket.settings.outputFormat,
                                              retryAfter: retryAfter) {
            // A new background task with an earliest start date, so it also runs if the app is
            // suspended before the delay is over. The job stays `.running`.
            let next = ticket.nextAttempt()
            if let problem = submit(next, notBefore: Date.now.addingTimeInterval(delay)) {
                markFailed(ticket.jobID, message: "\(message) The automatic retry couldn't be scheduled: \(problem)")
                return
            }
            Self.log.info("Attempt \(ticket.attempt) failed (\(error.localizedDescription, privacy: .public)); retrying in \(Int(delay))s")
            if let index = jobs.firstIndex(where: { $0.id == ticket.jobID }) {
                jobs[index].attempt = next.attempt
                updateRecord(jobs[index])
            }
            return
        }

        if ticket.attempt >= RetryPolicy.maxAttempts, RetryPolicy.isTransient(error) {
            message = RetryPolicy.exhaustedMessage(message, attempts: ticket.attempt)
        }
        markFailed(ticket.jobID, message: message)
    }

    /// Adds an attempt to its job's log. `handleFailure` then saves the job, whatever comes next.
    private func record(_ attemptLog: GenerationAttemptLog?, message: String, jobID: Job.ID) {
        guard var attemptLog, let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        attemptLog.message = message
        jobs[index].attemptLog = GenerationFailureReport.appending(attemptLog, to: jobs[index].attemptLog)
        Self.log.error("Attempt \(attemptLog.attempt) failed: \(attemptLog.resultLabel, privacy: .public) after \(Int(attemptLog.duration))s, request \(attemptLog.requestID ?? "none", privacy: .public)")
    }

    /// Saves a finished result to the library, then clears the job.
    private func finish(_ output: OpenAIImageClient.Output, for ticket: GenerationTicket) async {
        do {
            let images = try await Self.commit(output, for: ticket, in: context)
            // Before the job is removed, so the Live Activity's summary counts these images.
            observer?.generationSaved(jobID: ticket.jobID, prompt: ticket.prompt, images: images)
            libraryObserver?.imagesAdded(images.map(\.id))
            removeJob(ticket.jobID)
            completedCount += 1
        } catch {
            // Nothing was added to the library. Keep the output so Retry can save it again.
            if jobs.contains(where: { $0.id == ticket.jobID }) {
                heldOutputs[ticket.jobID] = (ticket, output)
            }
            markFailed(ticket.jobID, message: "Couldn't save the image: \(error.localizedDescription)")
        }
    }

    /// Jobs restored as running whose request no longer exists (e.g. the app was force-quit,
    /// which cancels background requests) can never finish, so mark them as failed.
    private func reconcile(_ restoredRunning: [Job.ID]) async {
        let active = await session.activeJobIDs()
        for id in restoredRunning where !active.contains(id) {
            guard let job = jobs.first(where: { $0.id == id }), !job.isFailed else { continue }
            markFailed(id, message: Self.interruptedMessage, announce: false)
        }
    }

    /// Adds a batch to the library all-or-nothing: every file is written first, then all records
    /// are inserted and saved once. On any failure the library and the image folder are left as
    /// they were, so retrying can't create duplicates. The closures exist so tests can inject failures.
    /// Returns the new library images, in order.
    @discardableResult
    static func commit(
        _ output: OpenAIImageClient.Output,
        for ticket: GenerationTicket,
        in context: ModelContext,
        now: Date = .now,
        writeFile: (Data, String) async throws -> Void = { try await ImageStore.save($0, fileName: $1) },
        removeFile: (String) throws -> Void = { try ImageStore.delete(fileName: $0) },
        persist: (ModelContext) throws -> Void = { try $0.save() }
    ) async throws -> [GeneratedImage] {
        let batchID = UUID()
        let duration = now.timeIntervalSince(ticket.startedAt)
        let reportedSize = output.size.flatMap(ImageSize.init(apiValue:))
        // Tokens are reported for the whole request; attribute them evenly across images.
        let share = { (tokens: Int?) in tokens.map { $0 / max(output.images.count, 1) } }

        func discard(_ fileNames: [String]) {
            for name in fileNames {
                do { try removeFile(name) } catch {
                    log.error("Couldn't remove \(name, privacy: .public) after a failed save: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // 1. Write every file. A failure removes the ones already written.
        var written: [(fileName: String, data: Data)] = []
        for image in output.images {
            let data = ticket.settings.outputFormat.isVector ? SVGDocument.addingSize(reportedSize, to: image) : image
            let fileName = ImageStore.makeFileName(format: ticket.settings.outputFormat, date: now)
            do {
                try await writeFile(data, fileName)
            } catch {
                discard(written.map(\.fileName) + [fileName])
                throw error
            }
            written.append((fileName, data))
        }

        // 2. Insert all records and save once. On failure take them out again, and the files too.
        var inserted: [GeneratedImage] = []
        for (index, item) in written.enumerated() {
            let dimensions = ImageStore.dimensions(of: item.data, format: ticket.settings.outputFormat, reported: reportedSize)
            let image = GeneratedImage(
                // Offset by a millisecond so a batch keeps its order in the library.
                createdAt: now.addingTimeInterval(Double(index) / 1000),
                prompt: ticket.prompt,
                revisedPrompt: output.revisedPrompts[safe: index] ?? nil,
                settings: ticket.settings,
                width: dimensions.width,
                height: dimensions.height,
                resolvedQuality: output.quality,
                resolvedBackground: output.background,
                fileName: item.fileName,
                fileSize: item.data.count,
                batchID: batchID,
                duration: duration,
                inputTokens: share(output.inputTokens),
                outputTokens: share(output.outputTokens),
                svgInputTokens: output.svgInputTokens,
                svgOutputTokens: output.svgOutputTokens,
                referenceFileNames: ticket.referenceFileNames,
                markupFileName: ticket.markupFileName
            )
            context.insert(image)
            inserted.append(image)
        }
        do {
            try persist(context)
        } catch {
            for image in inserted { context.delete(image) }
            discard(written.map(\.fileName))
            throw error
        }
        return inserted
    }

    static func message(for error: any Error, settings: GenerationSettings) -> String {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            // A cancellation we didn't ask for: the system stopped it, e.g. after a force-quit.
            return interruptedMessage
        }
        if case .api(status: 403, _, _)? = error as? OpenAIError, settings.outputFormat.mayRequirePreviewAccess {
            return "\(error.localizedDescription) \(settings.outputFormat.displayName) output may need preview access for this model."
        }
        if settings.outputFormat.isVector, RetryPolicy.isBadGateway(error) {
            return "\(error.localizedDescription) Retrying may not help with this prompt. Use Edit Prompt to try another SVG Author in the options."
        }
        return error.localizedDescription
    }

    // MARK: Job bookkeeping

    /// `announce: false` is for jobs found dead at launch: the user is opening the app and sees
    /// them there, so there's no haptic or notification.
    private func markFailed(_ id: Job.ID, message: String, announce: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if announce {
            // Before the state changes, so the Live Activity's summary counts this failure.
            observer?.generationFailed(jobID: id, prompt: jobs[index].prompt, message: message)
        }
        jobs[index].state = .failed(message)
        updateRecord(jobs[index])
        if announce { failureCount += 1 }
    }

    private func removeJob(_ id: Job.ID) {
        let references = jobs.first { $0.id == id }?.referenceStoreFileNames ?? []
        withAnimation(.snappy) { jobs.removeAll { $0.id == id } }
        defer { releaseReferences(references) }
        heldOutputs[id] = nil
        do {
            try context.delete(model: PendingGeneration.self, where: #Predicate { $0.id == id })
        } catch {
            Self.log.error("Couldn't delete pending record: \(error.localizedDescription, privacy: .public)")
        }
        // If this fails, the stale record comes back as a failed tile after a relaunch, which the
        // user can dismiss. The images themselves are already safe.
        saveContext("remove pending generation")
    }

    /// Mirrors a job to its record, creating the record if the original insert never made it.
    private func updateRecord(_ job: Job) {
        let id = job.id
        let record: PendingGeneration
        do {
            if let existing = try context.fetch(FetchDescriptor<PendingGeneration>(predicate: #Predicate { $0.id == id })).first {
                record = existing
            } else {
                record = PendingGeneration(id: job.id, prompt: job.prompt, settings: job.settings,
                                           startedAt: job.startedAt, referenceFileNames: job.references,
                                           markupFileName: job.markupFileName)
                context.insert(record)
            }
        } catch {
            Self.log.error("Couldn't look up pending record: \(error.localizedDescription, privacy: .public)")
            return
        }
        record.startedAt = job.startedAt
        record.attempt = job.attempt
        record.attemptLog = job.attemptLog
        if case .failed(let message) = job.state {
            record.failureMessage = message
        } else {
            record.failureMessage = nil
        }
        saveContext("update pending generation")
    }

    @discardableResult
    private func saveContext(_ action: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            Self.log.error("Couldn't \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Library

    /// Each deletion is recorded for iCloud Sync (`LibraryDeletion`) in the same save that removes
    /// the image, so it's kept until iCloud confirms it whatever else fails.
    func delete(_ images: [GeneratedImage]) {
        let ids = images.map(\.id)
        let references = images.flatMap(\.referenceStoreFileNames)
        let problem = Self.deleteImages(images, in: context, journal: { try LibraryDeletion.record(ids, as: .pending, in: $0) })
        if let problem { alertMessage = problem }
        releaseReferences(references)
        announceDeleted(ids)
    }

    /// `keeping` is for files in `ReferenceStore` that something other than the library still
    /// needs: the composer's attachments.
    func deleteAll(keeping held: [String] = [], removeAllImageFiles: () throws -> Void = { try ImageStore.deleteAll() }) {
        let ids: [UUID]
        do {
            ids = try context.fetch(FetchDescriptor<GeneratedImage>()).map(\.id)
        } catch {
            // Without the IDs their deletions couldn't be recorded for iCloud, so nothing is deleted.
            Self.log.error("Couldn't list images to delete: \(error.localizedDescription, privacy: .public)")
            alertMessage = "Couldn't delete your images: \(error.localizedDescription)"
            return
        }
        let problem = Self.deleteEverything(in: context, removeAllFiles: removeAllImageFiles,
                                            journal: { try LibraryDeletion.record(ids, as: .pending, in: $0) })
        if let problem { alertMessage = problem }
        removeOrphanedReferences(referencedFileNames().union(held))
        announceDeleted(ids)
    }

    /// Passes on the images that are really gone: a failed save leaves them in the library.
    private func announceDeleted(_ ids: [UUID]) {
        guard let libraryObserver, !ids.isEmpty else { return }
        let remaining = Set(existingImageIDs(among: ids))
        let deleted = ids.filter { !remaining.contains($0) }
        if !deleted.isEmpty { libraryObserver.imagesDeleted(deleted) }
    }

    func existingImageIDs(among ids: [UUID]) -> [UUID] {
        do {
            return try context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { ids.contains($0.id) })).map(\.id)
        } catch {
            // Can't tell, so assume nothing was deleted rather than delete it elsewhere too.
            Self.log.error("Couldn't check deleted images: \(error.localizedDescription, privacy: .public)")
            return ids
        }
    }

    // MARK: iCloud

    /// Adds images that arrived from iCloud. Each image's file, and any reference and markup files
    /// that came with it, are copied into place before its record is inserted, and all records are
    /// saved at once. Images already in the library keep their record, as images never change, but
    /// get back any reference or markup file they're missing.
    ///
    /// Returns the IDs that are now complete in the library; those in it but missing a reference or
    /// markup file that came with them, to deliver again; and those that couldn't be added at all.
    func addSyncedImages(
        _ images: [SyncedImage],
        installFile: (URL, URL) throws -> Bool = Studio.copyIfMissing
    ) -> (present: [UUID], incomplete: [UUID], failed: [UUID]) {
        guard !images.isEmpty else { return ([], [], []) }
        let ids = images.map(\.id)
        let existing: Set<UUID>
        do {
            existing = Set(try context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { ids.contains($0.id) })).map(\.id))
        } catch {
            Self.log.error("Couldn't look up synced images: \(error.localizedDescription, privacy: .public)")
            return ([], [], ids)
        }
        var present: [UUID] = []
        var incomplete: [UUID] = []
        var failed: [UUID] = []
        var inserted: [(record: GeneratedImage, complete: Bool)] = []
        var copiedImageFiles: [String] = []
        var claimedFileNames: Set<String> = []

        /// Copies the files for `ReferenceStore`. Returns whether all of them are in place.
        func installStoreFiles(of image: SyncedImage) -> Bool {
            var complete = true
            for (name, source) in image.storeFiles {
                do { _ = try installFile(source, ReferenceStore.url(for: name)) } catch {
                    Self.log.error("Couldn't copy synced reference \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    complete = false
                }
            }
            return complete
        }

        for image in images {
            if existing.contains(image.id) {
                if installStoreFiles(of: image) { present.append(image.id) } else { incomplete.append(image.id) }
                continue
            }
            guard !inserted.contains(where: { $0.record.id == image.id }) else { continue }
            let fileName = localFileName(for: image, claimed: claimedFileNames)
            do {
                if try installFile(image.file, ImageStore.url(for: fileName)) {
                    copiedImageFiles.append(fileName)
                }
            } catch {
                Self.log.error("Couldn't copy synced image \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(image.id)
                continue
            }
            claimedFileNames.insert(fileName)
            let record = GeneratedImage(synced: image)
            record.fileName = fileName
            context.insert(record)
            // An image missing a reference is still added, and delivered again to fill the gap.
            inserted.append((record, installStoreFiles(of: image)))
        }

        guard !inserted.isEmpty else { return (present, incomplete, failed) }
        do {
            try context.save()
            present += inserted.filter(\.complete).map(\.record.id)
            incomplete += inserted.filter { !$0.complete }.map(\.record.id)
        } catch {
            Self.log.error("Couldn't save synced images: \(error.localizedDescription, privacy: .public)")
            for item in inserted { context.delete(item.record) }
            for name in copiedImageFiles { try? ImageStore.delete(fileName: name) }
            failed += inserted.map(\.record.id)
        }
        return (present, incomplete, failed)
    }

    /// Where a synced image's file goes. Usually the name it had on the other device; a file already
    /// there is reused only if it's identical (left behind by a library reset). If the name is
    /// taken by another image, which two devices could pick by chance, it gets one of its own, so
    /// every image owns its file and deleting one never removes another's.
    private func localFileName(for image: SyncedImage, claimed: Set<String>) -> String {
        let name = image.fileName
        let usedByAnother = claimed.contains(name)
            || ((try? context.fetchCount(FetchDescriptor<GeneratedImage>(predicate: #Predicate { $0.fileName == name }))) ?? 1) > 0
        let url = ImageStore.url(for: name)
        let path = url.path(percentEncoded: false)
        let leftOver = FileManager.default.fileExists(atPath: path)
        let isThisImage = leftOver && FileManager.default.contentsEqual(atPath: path, andPath: image.file.path(percentEncoded: false))
        return usedByAnother || (leftOver && !isThisImage) ? Self.uniqueFileName(for: image) : name
    }

    nonisolated static func uniqueFileName(for image: SyncedImage) -> String {
        let source = URL(filePath: image.fileName)
        let stem = source.deletingPathExtension().lastPathComponent
        return "\(stem)-\(image.id.uuidString).\(source.pathExtension)"
    }

    /// Removes images that were deleted on another device, with their files and any reference files
    /// nothing else uses. Their recorded deletions (`LibraryDeletion`) are done with, so they're
    /// forgotten in the same save, including for images that are already gone from here. Returns
    /// the IDs still in the library because removing them failed.
    @discardableResult
    func removeSyncedImages(ids: [UUID]) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        let images: [GeneratedImage]
        do {
            images = try context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { ids.contains($0.id) }))
        } catch {
            Self.log.error("Couldn't look up synced deletions: \(error.localizedDescription, privacy: .public)")
            return ids
        }
        let forget: (ModelContext) throws -> Void = { try LibraryDeletion.forget(ids, in: $0) }
        guard !images.isEmpty else {
            do {
                try forget(context)
                try context.save()
            } catch {
                // Only costs a deletion sent again, or a removal tried again, that finds nothing.
                context.rollback()
                Self.log.error("Couldn't forget synced deletions: \(error.localizedDescription, privacy: .public)")
            }
            return []
        }
        let found = images.map(\.id)
        let references = images.flatMap(\.referenceStoreFileNames)
        if let problem = Self.deleteImages(images, in: context, journal: forget) { alertMessage = problem }
        releaseReferences(references)
        return existingImageIDs(among: found)
    }

    /// Copies a file unless the destination already has one. Returns whether it copied.
    nonisolated static func copyIfMissing(from source: URL, to destination: URL) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { return false }
        try FileManager.default.copyItem(at: source, to: destination)
        return true
    }

    // MARK: References

    /// Deletes reference and markup files that no image or job uses any more. Files still held by
    /// the composer are never passed here: the composer owns separate copies until it sends them.
    private func releaseReferences(_ names: [String]) {
        guard !names.isEmpty else { return }
        let inUse = referencedFileNames()
        ReferenceStore.delete(Set(names).subtracting(inUse))
    }

    private func referencedFileNames() -> Set<String> {
        var names = Set(jobs.flatMap(\.referenceStoreFileNames))
        do {
            for image in try context.fetch(FetchDescriptor<GeneratedImage>()) {
                names.formUnion(image.referenceStoreFileNames)
            }
        } catch {
            // If the library can't be read, treat every file as in use rather than risk deleting one.
            Self.log.error("Couldn't check reference usage: \(error.localizedDescription, privacy: .public)")
            let all = (try? FileManager.default.contentsOfDirectory(atPath: ReferenceStore.directory.path(percentEncoded: false))) ?? []
            names.formUnion(all)
        }
        return names
    }

    /// Deletes records first and files only once the records are gone, so a failure never leaves a
    /// library entry pointing at a missing file. `journal` makes changes to save with the deletion
    /// (see `LibraryDeletion`); if it throws, nothing is deleted. Returns a message for the user if
    /// anything failed.
    static func deleteImages(
        _ images: [GeneratedImage],
        in context: ModelContext,
        journal: (ModelContext) throws -> Void = { _ in },
        removeFile: (String) throws -> Void = { try ImageStore.delete(fileName: $0) }
    ) -> String? {
        guard !images.isEmpty else { return nil }
        let fileNames = images.map(\.fileName)
        do {
            for image in images { context.delete(image) }
            try journal(context)
            try context.save()
        } catch {
            context.rollback()
            log.error("Couldn't delete images: \(error.localizedDescription, privacy: .public)")
            return "Couldn't delete \(images.count == 1 ? "the image" : "the images"): \(error.localizedDescription)"
        }
        var failures = 0
        for name in fileNames {
            do { try removeFile(name) } catch {
                failures += 1
                log.error("Couldn't remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard failures > 0 else { return nil }
        return "Removed from your library, but \(failures == 1 ? "1 file" : "\(failures) files") couldn't be deleted from storage and may still take up space."
    }

    /// `journal` makes changes to save with the deletion, as for `deleteImages`.
    static func deleteEverything(
        in context: ModelContext,
        removeAllFiles: () throws -> Void = { try ImageStore.deleteAll() },
        journal: (ModelContext) throws -> Void = { _ in }
    ) -> String? {
        do {
            try context.delete(model: GeneratedImage.self)
            try journal(context)
            try context.save()
        } catch {
            context.rollback()
            log.error("Couldn't delete all images: \(error.localizedDescription, privacy: .public)")
            return "Couldn't delete your images: \(error.localizedDescription)"
        }
        do {
            try removeAllFiles()
            return nil
        } catch {
            log.error("Couldn't remove image files: \(error.localizedDescription, privacy: .public)")
            return "Your library was cleared, but some files couldn't be deleted from storage and may still take up space. \(error.localizedDescription)"
        }
    }

    #if DEBUG
    /// Adds placeholder jobs without making a request, for previews and UI checks.
    func addSampleJobs() {
        var settings = GenerationSettings()
        settings.count = 2
        jobs.append(Job(prompt: "A quiet harbour at dawn", settings: settings))
        jobs.append(Job(prompt: "Sample failure", settings: GenerationSettings(),
                        state: .failed("OpenAI rejected this API key. Check it in Settings.")))
    }
    #endif
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
