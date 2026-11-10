import DogMonitorCore
import Foundation
import UserNotifications

/// Attaches the event snapshot to dog-event pushes (`mutable-content: 1` + `snapshotUrl`).
/// If the download fails or time runs out, the push is shown without the image.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var download: URLSessionDownloadTask?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        guard let url = PushPayload.snapshotURL(in: content.userInfo) else {
            contentHandler(content)
            return
        }
        lock.lock()
        self.contentHandler = contentHandler
        self.content = content
        lock.unlock()

        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, _ in
            guard let self else { return }
            if let location, (response as? HTTPURLResponse)?.statusCode == 200,
               let attachment = Self.attachment(from: location) {
                self.lock.lock()
                self.content?.attachments = [attachment]
                self.lock.unlock()
            }
            self.deliver()
        }
        lock.lock()
        download = task
        lock.unlock()
        task.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let task = download
        lock.unlock()
        task?.cancel()
        deliver()
    }

    /// Calls the content handler exactly once.
    private func deliver() {
        lock.lock()
        let handler = contentHandler
        let content = content
        contentHandler = nil
        lock.unlock()
        if let handler, let content {
            handler(content)
        }
    }

    /// The downloaded temp file is deleted when the completion handler returns, so move it first.
    private static func attachment(from location: URL) -> UNNotificationAttachment? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            return try UNNotificationAttachment(
                identifier: "snapshot",
                url: destination,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
            )
        } catch {
            return nil
        }
    }
}
