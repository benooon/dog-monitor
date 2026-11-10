import Foundation

/// Which events the timeline asks for (`GET /events` query).
public struct TimelineFilter: Sendable, Hashable {
    /// Only this camera's events; nil for the whole household.
    public var cameraId: UUID?
    /// Only these types; empty means all types.
    public var types: Set<EventType>

    public init(cameraId: UUID? = nil, types: Set<EventType> = []) {
        self.cameraId = cameraId
        self.types = types
    }

    public static let all = TimelineFilter()

    /// Query items in a stable order (types sorted by their wire value).
    func queryItems(cursor: String?, limit: Int?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let cameraId {
            items.append(URLQueryItem(name: "cameraId", value: DogMonitorAPI.path(cameraId)))
        }
        if !types.isEmpty {
            items.append(URLQueryItem(name: "types", value: types.map(\.rawValue).sorted().joined(separator: ",")))
        }
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return items
    }
}

/// One page of `GET /events`, newest first. Pass `nextCursor` to get the page after it.
public struct TimelinePage: Decodable, Sendable, Hashable {
    public let events: [EventDTO]
    /// nil on the last page.
    public let nextCursor: String?

    public init(events: [EventDTO], nextCursor: String?) {
        self.events = events
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case events, nextCursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Skip events this app version can't read (e.g. a type added on the server later)
        // instead of failing the whole page.
        events = try container.decode([Lenient<EventDTO>].self, forKey: .events).compactMap(\.value)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }

    public var hasMore: Bool { nextCursor != nil }
}

/// Decodes a value, or nil if it doesn't fit, without failing the surrounding array.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// `GET /events/:id/media`: short-lived download URLs for an event's clip and snapshot.
public struct EventMediaDTO: Codable, Sendable, Hashable {
    public let clipUrl: URL?
    public let snapshotUrl: URL?
    /// When the URLs stop working; fetch again after this.
    public let expiresAt: Date

    public init(clipUrl: URL?, snapshotUrl: URL?, expiresAt: Date) {
        self.clipUrl = clipUrl
        self.snapshotUrl = snapshotUrl
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }
}

/// Body of `PUT /events/:id/feedback`. `nil` clears the verdict, and is sent as JSON `null`.
struct EventFeedbackRequest: Encodable {
    let feedback: DogEvent.Feedback?

    private enum CodingKeys: String, CodingKey {
        case feedback
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(feedback, forKey: .feedback)
    }
}
