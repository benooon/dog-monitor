import DogMonitorCore
import Foundation
import os

/// The realtime WebSocket (`GET /ws`) with automatic reconnect (exponential backoff).
///
/// Subscribe with `events()`; `connected` / `disconnected` bracket every session, so consumers
/// can reset state (e.g. assume no viewers) when the link drops.
final class RealtimeConnection: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case connected
        case disconnected
        case message(RealtimeServerMessage)
    }

    private let makeRequest: @Sendable () -> URLRequest
    private let session: URLSession
    private let broadcaster = Broadcaster<Event>()
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "Realtime")
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    init(session: URLSession = .shared, makeRequest: @escaping @Sendable () -> URLRequest) {
        self.session = session
        self.makeRequest = makeRequest
    }

    func events() -> AsyncStream<Event> {
        broadcaster.subscribe(bufferingNewest: 64)
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task.detached(priority: .utility) { [self] in
            await run()
        }
    }

    func stop() {
        lock.lock()
        let loop = self.loop
        let socket = self.socket
        self.loop = nil
        self.socket = nil
        lock.unlock()
        loop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Sends a message if connected; messages sent while offline are dropped (heartbeats repeat anyway).
    func send(_ message: RealtimeClientMessage) async {
        guard let socket = currentSocket() else { return }
        do {
            let text = String(decoding: try message.encoded(), as: UTF8.self)
            try await socket.send(.string(text))
        } catch {
            logger.debug("Send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func currentSocket() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return socket
    }

    private func setSocket(_ socket: URLSessionWebSocketTask?) {
        lock.lock()
        self.socket = socket
        lock.unlock()
    }

    private func run() async {
        var backoff = ReconnectBackoff()
        while !Task.isCancelled {
            let socket = session.webSocketTask(with: makeRequest())
            setSocket(socket)
            socket.resume()
            do {
                // A pong proves the upgrade succeeded (auth included) even if no message arrives.
                try await Self.ping(socket)
                backoff.reset()
                broadcaster.yield(.connected)
                while !Task.isCancelled {
                    let frame = try await socket.receive()
                    if let message = Self.decode(frame) {
                        broadcaster.yield(.message(message))
                    }
                }
                broadcaster.yield(.disconnected)
            } catch {
                logger.info("Realtime connection ended: \(error.localizedDescription, privacy: .public)")
                broadcaster.yield(.disconnected)
            }
            socket.cancel(with: .goingAway, reason: nil)
            setSocket(nil)
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(backoff.nextDelay()))
        }
    }

    private static func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func decode(_ frame: URLSessionWebSocketTask.Message) -> RealtimeServerMessage? {
        let data: Data
        switch frame {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return nil
        }
        return try? RealtimeServerMessage.decode(data)
    }
}
