import Foundation

/// One pending call to the backend for an engine output.
public enum EventUpload: Codable, Sendable, Equatable {
    case create(CreateEventRequest)
    case update(id: UUID, UpdateEventRequest)

    /// The uploads an engine output needs. `resumed` needs none: the event is already on the server.
    public static func uploads(for output: EngineOutput) -> [EventUpload] {
        switch output {
        case .started(let event):
            [.create(CreateEventRequest(event))]
        case .resumed:
            []
        case .escalated(let event, let duration):
            [.update(id: event.id, UpdateEventRequest(escalationSeconds: duration))]
        case .ended(let event):
            [.update(id: event.id, UpdateEventRequest(endedAt: event.endedAt))]
        }
    }
}

/// Where the queue is persisted between launches.
public protocol EventQueueStore: Sendable {
    func load() -> Data?
    func save(_ data: Data?) throws
}

/// A JSON file (e.g. in Application Support).
public struct FileEventQueueStore: EventQueueStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Data? {
        try? Data(contentsOf: url)
    }

    public func save(_ data: Data?) throws {
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public final class InMemoryEventQueueStore: EventQueueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    public func save(_ data: Data?) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }
}

/// Sends engine outputs to the backend in order, persisting what hasn't been sent so events
/// survive offline periods and app restarts (SPEC §7 "queue events locally").
///
/// Network and server (5xx, 429) failures stop the flush and keep the item for a retry;
/// other 4xx responses drop it, since retrying a rejected request can never succeed.
public actor EventUploader {
    public static let maxQueueLength = 500

    private let store: any EventQueueStore
    private var queue: [EventUpload]
    private var isFlushing = false

    public init(store: any EventQueueStore) {
        self.store = store
        queue = store.load().flatMap { try? JSONCoding.makeDecoder().decode([EventUpload].self, from: $0) } ?? []
    }

    public var pending: [EventUpload] { queue }

    public func enqueue(_ outputs: [EngineOutput]) {
        let uploads = outputs.flatMap(EventUpload.uploads(for:))
        guard !uploads.isEmpty else { return }
        queue.append(contentsOf: uploads)
        if queue.count > Self.maxQueueLength {
            queue.removeFirst(queue.count - Self.maxQueueLength)
        }
        persist()
    }

    /// Sends queued uploads in order until one fails with a retryable error. Returns how many were sent.
    @discardableResult
    public func flush(using api: DogMonitorAPI) async -> Int {
        guard !isFlushing else { return 0 }
        isFlushing = true
        defer { isFlushing = false }
        var sent = 0
        drain: while let next = queue.first {
            do {
                switch next {
                case .create(let request):
                    _ = try await api.createEvent(request)
                case .update(let id, let request):
                    _ = try await api.updateEvent(id: id, request)
                }
                sent += 1
            } catch let error as APIError where Self.isRetryable(error) {
                break drain
            } catch {
                // Rejected for good (validation, unknown event...): drop it.
            }
            queue.removeFirst()
            persist()
        }
        return sent
    }

    static func isRetryable(_ error: APIError) -> Bool {
        switch error {
        case .transport, .invalidResponse:
            true
        case .http(let status, _):
            status >= 500 || status == 429 || status == 401
        case .decoding:
            false
        }
    }

    private func persist() {
        let data = queue.isEmpty ? nil : try? JSONCoding.makeEncoder().encode(queue)
        try? store.save(data)
    }
}
