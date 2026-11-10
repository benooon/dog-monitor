import Foundation

/// One event file waiting to be uploaded and attached to its event.
public struct MediaUpload: Codable, Sendable, Equatable {
    public var eventID: UUID
    public var kind: MediaKind
    public var createdAt: Date
    /// Failed attempts the server answered (not counting offline periods).
    public var attempts: Int

    public init(eventID: UUID, kind: MediaKind, createdAt: Date, attempts: Int = 0) {
        self.eventID = eventID
        self.kind = kind
        self.createdAt = createdAt
        self.attempts = attempts
    }
}

/// Uploads event clips and snapshots through presigned URLs and attaches their keys to the
/// event (`PATCH /events/:id`), with a persisted queue that survives offline periods and
/// relaunches.
///
/// Files live at `<directory>/<EVENT-UUID>/<kind.fileName>` (the recorder's layout) and are
/// deleted once uploaded. Paths are rebuilt from the directory on each launch because the
/// app container path can change between installs.
public actor MediaUploader {
    /// Server-side failures (e.g. the event is not created yet) tolerated per item.
    public static let maxAttempts = 30
    /// Items older than this are dropped, uploaded or not (the bucket keeps 7 days anyway).
    public static let maxAge: TimeInterval = 2 * 24 * 3600
    public static let maxQueueLength = 200

    public let directory: URL
    private let store: any EventQueueStore
    private let now: @Sendable () -> Date
    private var queue: [MediaUpload]
    private var isFlushing = false

    public init(directory: URL, store: any EventQueueStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.store = store
        self.now = now
        queue = store.load().flatMap { try? JSONCoding.makeDecoder().decode([MediaUpload].self, from: $0) } ?? []
    }

    public var pending: [MediaUpload] { queue }

    public nonisolated func fileURL(eventID: UUID, kind: MediaKind) -> URL {
        directory
            .appendingPathComponent(eventID.uuidString, isDirectory: true)
            .appendingPathComponent(kind.fileName)
    }

    /// Queues a saved file for upload. A file already queued is not added twice.
    public func enqueue(eventID: UUID, kind: MediaKind) {
        guard !queue.contains(where: { $0.eventID == eventID && $0.kind == kind }) else { return }
        queue.append(MediaUpload(eventID: eventID, kind: kind, createdAt: now()))
        if queue.count > Self.maxQueueLength {
            queue.removeFirst(queue.count - Self.maxQueueLength)
        }
        persist()
    }

    /// Uploads one file right away and returns its storage key, without touching the event.
    /// Used to put the snapshot key into `POST /events` so the first push carries the image.
    /// The local file is deleted on success.
    public func uploadNow(eventID: UUID, kind: MediaKind, using api: DogMonitorAPI) async throws -> String {
        let key = try await upload(eventID: eventID, kind: kind, using: api)
        removeFile(eventID: eventID, kind: kind)
        return key
    }

    /// Uploads queued files and attaches them to their events. Stops at the first network or
    /// 5xx failure (the rest would fail too). An event that does not exist yet (404, its
    /// `POST /events` is still queued) is retried later. Returns how many files were attached.
    @discardableResult
    public func flush(using api: DogMonitorAPI) async -> Int {
        guard !isFlushing else { return 0 }
        isFlushing = true
        defer { isFlushing = false }

        var attached = 0
        var remaining: [MediaUpload] = []
        let snapshot = queue
        var items = snapshot[...]
        drain: while let item = items.popFirst() {
            guard isAlive(item) else {
                removeFile(eventID: item.eventID, kind: item.kind)
                continue
            }
            do {
                let key = try await upload(eventID: item.eventID, kind: item.kind, using: api)
                let update = item.kind == .clip ? UpdateEventRequest(clipKey: key) : UpdateEventRequest(snapshotKey: key)
                _ = try await api.updateEvent(id: item.eventID, update)
                removeFile(eventID: item.eventID, kind: item.kind)
                attached += 1
            } catch MediaUploadError.missingFile {
                // Nothing to upload (deleted or never written).
            } catch let error as APIError where Self.isOffline(error) {
                remaining.append(item)
                remaining.append(contentsOf: items)
                break drain
            } catch let error as APIError where Self.isRetryable(error) {
                var retry = item
                retry.attempts += 1
                if retry.attempts < Self.maxAttempts {
                    remaining.append(retry)
                } else {
                    removeFile(eventID: item.eventID, kind: item.kind)
                }
            } catch {
                // Rejected for good (invalid key, bad request): drop it.
                removeFile(eventID: item.eventID, kind: item.kind)
            }
        }
        // Keep anything enqueued while this flush was awaiting the network.
        let processed = Set(snapshot.map(Self.identity))
        let added = queue.filter { !processed.contains(Self.identity($0)) }
        queue = remaining + added
        persist()
        return attached
    }

    // MARK: - Private

    private struct Identity: Hashable {
        let eventID: UUID
        let kind: MediaKind
    }

    private static func identity(_ item: MediaUpload) -> Identity {
        Identity(eventID: item.eventID, kind: item.kind)
    }

    private func upload(eventID: UUID, kind: MediaKind, using api: DogMonitorAPI) async throws -> String {
        guard let data = try? Data(contentsOf: fileURL(eventID: eventID, kind: kind)), !data.isEmpty else {
            throw MediaUploadError.missingFile
        }
        let uploads = try await api.requestUploads(eventId: eventID, kinds: [kind])
        guard let target = uploads[kind] else { throw APIError.invalidResponse }
        try await api.upload(data, to: target)
        return target.key
    }

    private func isAlive(_ item: MediaUpload) -> Bool {
        now().timeIntervalSince(item.createdAt) < Self.maxAge && item.attempts < Self.maxAttempts
    }

    private nonisolated func removeFile(eventID: UUID, kind: MediaKind) {
        let url = fileURL(eventID: eventID, kind: kind)
        try? FileManager.default.removeItem(at: url)
        let folder = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static func isOffline(_ error: APIError) -> Bool {
        switch error {
        case .transport: true
        case .http(let status, _): status >= 500 || status == 429 || status == 401
        case .invalidResponse, .decoding: false
        }
    }

    static func isRetryable(_ error: APIError) -> Bool {
        switch error {
        case .http(let status, _): status == 404
        case .invalidResponse: true
        case .transport, .decoding: false
        }
    }

    private func persist() {
        let data = queue.isEmpty ? nil : try? JSONCoding.makeEncoder().encode(queue)
        try? store.save(data)
    }
}

enum MediaUploadError: Error {
    case missingFile
}
