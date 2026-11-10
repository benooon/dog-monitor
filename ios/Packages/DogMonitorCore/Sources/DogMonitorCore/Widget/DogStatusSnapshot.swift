import Foundation

/// What the home screen widget shows for one camera. The viewer app writes these into the
/// shared app group whenever it learns something new; the widget only reads them, so it can
/// say how old the information is instead of pretending to be live.
public struct DogStatusSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var cameraId: UUID
    public var cameraName: String
    public var dogName: String?
    public var state: DogState?
    public var online: Bool
    public var updatedAt: Date

    public var id: UUID { cameraId }

    public init(cameraId: UUID, cameraName: String, dogName: String?, state: DogState?, online: Bool, updatedAt: Date) {
        self.cameraId = cameraId
        self.cameraName = cameraName
        self.dogName = dogName
        self.state = state
        self.online = online
        self.updatedAt = updatedAt
    }

    /// After this long without an update the widget stops showing the state as current.
    public static let staleAfter: TimeInterval = 30 * 60

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.staleAfter
    }

    /// Same rules as the Live Activity: offline, stale or unclassified reads as `.unknown`.
    public func displayState(at now: Date) -> DogState {
        guard online, !isStale(at: now), let state else { return .unknown }
        return state
    }

    /// The camera the widget shows: the first one with something to say, else the first one.
    public static func featured(in snapshots: [DogStatusSnapshot]) -> DogStatusSnapshot? {
        snapshots.first { $0.online && $0.state != nil } ?? snapshots.first
    }

    /// Encodes for the shared defaults (ISO-8601 dates).
    public static func encode(_ snapshots: [DogStatusSnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(snapshots)
    }

    /// Decodes what `encode` wrote; anything unreadable (e.g. an older format) reads as empty.
    public static func decode(_ data: Data?) -> [DogStatusSnapshot] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DogStatusSnapshot].self, from: data)) ?? []
    }
}
