import Foundation

/// The events a timeline screen has loaded so far: pages appended in order, without duplicates,
/// grouped by day for display. Pure state, so the screen's model only does the networking.
public struct TimelineFeed: Sendable, Equatable {
    /// Newest first, unique by id.
    public private(set) var events: [EventDTO] = []
    /// Cursor for the next page; nil before the first page and after the last one.
    public private(set) var nextCursor: String?
    /// True once the first page arrived.
    public private(set) var hasLoadedFirstPage = false

    public init() {}

    public init(events: [EventDTO], nextCursor: String? = nil) {
        self.init()
        replace(with: TimelinePage(events: events, nextCursor: nextCursor))
    }

    /// Whether there is another page to ask for.
    public var hasMore: Bool { nextCursor != nil }

    public var isEmpty: Bool { events.isEmpty }

    /// Starts over with a fresh first page (pull to refresh, a new filter).
    public mutating func replace(with page: TimelinePage) {
        events = []
        append(page)
    }

    /// Adds the next page. Events already shown (an event can move between pages while new
    /// ones arrive) keep their place and take the newer copy.
    public mutating func append(_ page: TimelinePage) {
        var index: [UUID: Int] = [:]
        for (position, event) in events.enumerated() {
            index[event.id] = position
        }
        for event in page.events {
            if let position = index[event.id] {
                events[position] = event
            } else {
                index[event.id] = events.count
                events.append(event)
            }
        }
        nextCursor = page.nextCursor
        hasLoadedFirstPage = true
    }

    /// Swaps in the server's copy of one event (e.g. after `PUT /events/:id/feedback`).
    public mutating func update(_ event: EventDTO) {
        guard let position = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[position] = event
    }

    public func event(id: UUID) -> EventDTO? {
        events.first { $0.id == id }
    }

    /// Events grouped by the calendar day they started on, newest day first.
    public func days(calendar: Calendar = .current) -> [TimelineDay] {
        var days: [TimelineDay] = []
        for event in events {
            let day = calendar.startOfDay(for: event.startedAt)
            if days.last?.day == day {
                days[days.count - 1].events.append(event)
            } else if let position = days.firstIndex(where: { $0.day == day }) {
                // Out-of-order input; keep the day together anyway.
                days[position].events.append(event)
            } else {
                days.append(TimelineDay(day: day, events: [event]))
            }
        }
        return days.sorted { $0.day > $1.day }
    }
}

/// One day's section of the timeline.
public struct TimelineDay: Sendable, Equatable, Identifiable {
    /// Start of the day in the calendar used for grouping.
    public let day: Date
    public var events: [EventDTO]

    public var id: Date { day }
}

extension EventType {
    /// Detections a viewer can mark right or wrong. Camera health and summaries aren't guesses.
    public var acceptsFeedback: Bool {
        switch self {
        case .prolongedBarking, .whining, .forbiddenZone, .atDoor, .notVisible, .calmedDown: true
        case .cameraOffline, .lowBattery, .overheating, .dailySummary: false
        }
    }

    /// Types offered as timeline filters, in display order: the dog first, then the camera.
    public static let timelineFilters: [EventType] = [
        .prolongedBarking, .whining, .atDoor, .forbiddenZone, .notVisible, .calmedDown,
        .cameraOffline, .lowBattery, .overheating, .dailySummary,
    ]
}

extension EventDTO {
    /// Whether `GET /events/:id/media` can return something to show.
    public var hasMedia: Bool { clipKey != nil || snapshotKey != nil }

    /// How long the event lasted, when it has ended.
    public var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    /// A copy with a different verdict, shown right away while the request is in flight.
    public func with(feedback: DogEvent.Feedback?) -> EventDTO {
        EventDTO(
            id: id, householdId: householdId, cameraId: cameraId, type: type, state: state,
            startedAt: startedAt, endedAt: endedAt, confidence: confidence,
            clipKey: clipKey, snapshotKey: snapshotKey, feedback: feedback
        )
    }
}
