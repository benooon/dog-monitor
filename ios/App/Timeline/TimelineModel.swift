import DogMonitorCore
import Foundation
import Observation

/// Loads the household's events page by page (`GET /events`), applies the screen's filters and
/// sends right/wrong verdicts (`PUT /events/:id/feedback`). Grouping and de-duplication live in
/// `TimelineFeed` (core).
@MainActor
@Observable
final class TimelineModel {
    enum Phase: Equatable {
        case loading, ready, failed
    }

    static let pageSize = 30

    private(set) var phase: Phase = .loading
    private(set) var feed = TimelineFeed()
    /// True while the next page is on its way.
    private(set) var isLoadingMore = false
    /// Set when sending a verdict failed, so the screen can tell the user once.
    private(set) var feedbackFailed = false

    let cameras: [DeviceDTO]
    /// nil shows every camera.
    var cameraId: UUID? {
        didSet { if cameraId != oldValue { reload() } }
    }
    /// Empty shows every type.
    var types: Set<EventType> = [] {
        didSet { if types != oldValue { reload() } }
    }

    private let api: DogMonitorAPI
    private var loadTask: Task<Void, Never>?

    init(api: DogMonitorAPI, cameras: [DeviceDTO], loaded: [EventDTO]? = nil) {
        self.api = api
        self.cameras = cameras
        if let loaded {
            feed = TimelineFeed(events: loaded)
            phase = .ready
        }
    }

    var filter: TimelineFilter {
        TimelineFilter(cameraId: cameraId, types: types)
    }

    var isFiltered: Bool { cameraId != nil || !types.isEmpty }

    func cameraName(for event: EventDTO) -> String? {
        guard let id = event.cameraId else { return nil }
        return cameras.first { $0.id == id }?.name
    }

    func clearFilters() {
        cameraId = nil
        types = []
    }

    /// Loads the first page again (first appearance, pull to refresh, retry).
    func refresh() async {
        if !feed.hasLoadedFirstPage { phase = .loading }
        let requested = self.filter
        do {
            let page = try await api.timeline(requested, limit: Self.pageSize)
            // A filter change while this was in flight started a newer load; drop this page.
            guard requested == filter else { return }
            feed.replace(with: page)
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            guard requested == filter else { return }
            if !feed.hasLoadedFirstPage || feed.isEmpty { phase = .failed }
        }
    }

    /// Asks for the next page when the user reaches the end of the list.
    func loadMore() async {
        guard phase == .ready, feed.hasMore, !isLoadingMore, let cursor = feed.nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let requested = self.filter
        do {
            let page = try await api.timeline(requested, cursor: cursor, limit: Self.pageSize)
            guard requested == filter, cursor == feed.nextCursor else { return }
            feed.append(page)
        } catch let error as APIError where error.code == "invalid_cursor" {
            // The cursor went stale (e.g. events were deleted by retention); start over.
            await refresh()
        } catch {
            // Leave the list as it is; reaching the end again retries.
        }
    }

    /// Marks a detection right or wrong, or clears the verdict when it's tapped again.
    func toggleFeedback(_ verdict: DogEvent.Feedback, for event: EventDTO) async {
        let current = feed.event(id: event.id) ?? event
        let next: DogEvent.Feedback? = current.feedback == verdict ? nil : verdict
        feed.update(current.with(feedback: next))
        feedbackFailed = false
        do {
            let saved = try await api.setFeedback(eventId: event.id, next)
            feed.update(saved)
        } catch {
            feed.update(current)
            feedbackFailed = true
        }
    }

    /// Short-lived clip and snapshot URLs for one event.
    func media(for event: EventDTO) async throws -> EventMediaDTO {
        try await api.eventMedia(eventId: event.id)
    }

    private func reload() {
        feed = TimelineFeed()
        phase = .loading
        loadTask?.cancel()
        loadTask = Task { await self.refresh() }
    }
}
