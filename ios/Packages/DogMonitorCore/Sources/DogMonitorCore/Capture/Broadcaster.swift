import Foundation

/// Fans one producer out to many async consumers.
///
/// Each `subscribe` call returns its own `AsyncStream`. Every subscriber has a bounded
/// buffer that keeps only the newest elements, so a slow consumer (e.g. heavy video
/// analysis) drops old frames instead of stalling the producer or the other consumers.
/// `yield` is cheap and safe to call from any thread, such as an AVFoundation callback queue.
public final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var isFinished = false

    public init() {}

    /// Number of active subscribers. Producers can skip expensive work when this is 0.
    public var subscriberCount: Int {
        locked { continuations.count }
    }

    /// A new stream of everything yielded from now on.
    /// - Parameter bufferingNewest: how many unconsumed elements to keep for this subscriber.
    public func subscribe(bufferingNewest limit: Int = 1) -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(
            bufferingPolicy: .bufferingNewest(max(limit, 1))
        )
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        let alreadyFinished: Bool = locked {
            if isFinished { return true }
            continuations[id] = continuation
            return false
        }
        if alreadyFinished {
            continuation.finish()
        }
        return stream
    }

    /// Delivers `element` to every current subscriber.
    public func yield(_ element: Element) {
        let targets = locked { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(element)
        }
    }

    /// Ends every stream. Later subscribers get an already-finished stream.
    public func finish() {
        let targets: [AsyncStream<Element>.Continuation] = locked {
            isFinished = true
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func remove(_ id: UUID) {
        _ = locked { continuations.removeValue(forKey: id) }
    }
}
