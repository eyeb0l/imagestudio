import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

/// Posts a local notification when a generation finishes or fails while Image Studio isn't in the
/// foreground, and routes taps on those notifications back into the app.
@Observable
final class GenerationNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GenerationNotifier()

    /// The image a tapped notification points to. The library opens it and clears this.
    var openedImageID: UUID?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var hasRequestedAuthorization = false

    nonisolated static let imageIDKey = "imageID"
    static let threadIdentifier = "generations"
    private static let thumbnailSize = 600
    private static let log = Logger(subsystem: "com.eyeb0l.ImageStudio", category: "Notifications")

    private override init() {
        super.init()
    }

    /// Must be called before the app finishes launching so taps that launch the app are delivered.
    func activate() {
        center.delegate = self
    }

    /// Asks for permission the first time the user starts a generation, when the reason is clear.
    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Self.log.error("Couldn't request notification permission: \(error.localizedDescription, privacy: .public)")
        }
    }

    func announceSaved(jobID: UUID, prompt: String, images: [(id: UUID, fileName: String)]) async {
        guard let first = images.first else { return }
        let content = Self.savedContent(prompt: prompt, imageCount: images.count, firstImageID: first.id)
        if let attachment = await Self.thumbnailAttachment(fileName: first.fileName) {
            content.attachments = [attachment]
        }
        await post(content, id: jobID)
    }

    func announceFailure(jobID: UUID, prompt: String, message: String) async {
        await post(Self.failureContent(prompt: prompt, message: message), id: jobID)
    }

    static func savedContent(prompt: String, imageCount: Int, firstImageID: UUID) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = imageCount == 1 ? "Image ready" : "\(imageCount) images ready"
        content.body = prompt
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        content.userInfo = [imageIDKey: firstImageID.uuidString]
        return content
    }

    static func failureContent(prompt: String, message: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Generation failed"
        content.subtitle = prompt
        content.body = message
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        return content
    }

    /// The library image a notification opens, if any.
    nonisolated static func imageID(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[imageIDKey] as? String).flatMap(UUID.init(uuidString:))
    }

    private func post(_ content: UNNotificationContent, id: UUID) async {
        // In the app, the library already shows the result (with a haptic).
        guard UIApplication.shared.applicationState != .active else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        do {
            // Keyed by job, so a job never shows more than one notification.
            try await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
        } catch {
            Self.log.error("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A small copy of the image for the notification. Attachments are moved into the system's
    /// store, so the original must never be attached directly.
    private static func thumbnailAttachment(fileName: String) async -> UNNotificationAttachment? {
        guard let image = await ImageLoader.shared.image(fileName: fileName, maxPixelSize: thumbnailSize),
              let data = image.pngData() else { return nil }
        let url = URL.temporaryDirectory.appending(path: "notification-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "thumbnail", url: url)
        } catch {
            log.error("Couldn't attach thumbnail: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Only posted from the background, but one can land just as the app opens.
        [.list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = Self.imageID(in: response.notification.request.content.userInfo) else { return }
        await MainActor.run { openedImageID = id }
    }
}
