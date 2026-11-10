import DogMonitorCore
import Foundation

extension DogMonitorAPI {
    /// A client the timeline previews never call (they pass loaded events).
    static var timelinePreview: DogMonitorAPI {
        DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!)
    }
}

extension TimelineModel {
    /// Two days of sample events, no network.
    static var preview: TimelineModel {
        let household = UUID()
        let camera = UUID()
        let now = Date.now
        func event(_ type: EventType, hoursAgo: Double, minutes: Double? = nil, feedback: DogEvent.Feedback? = nil) -> EventDTO {
            let start = now.addingTimeInterval(-hoursAgo * 3600)
            return EventDTO(
                id: UUID(), householdId: household, cameraId: camera, type: type,
                startedAt: start, endedAt: minutes.map { start.addingTimeInterval($0 * 60) },
                clipKey: "clips/sample.mp4", feedback: feedback
            )
        }
        let events = [
            event(.calmedDown, hoursAgo: 0.5),
            event(.prolongedBarking, hoursAgo: 1, minutes: 4, feedback: .correct),
            event(.atDoor, hoursAgo: 3, minutes: 12),
            event(.whining, hoursAgo: 26, minutes: 2, feedback: .wrong),
            event(.cameraOffline, hoursAgo: 30, minutes: 45),
            event(.dailySummary, hoursAgo: 36),
        ]
        let livingRoom = DeviceDTO(id: camera, householdId: household, name: "Living room", role: .camera, createdAt: now)
        return TimelineModel(api: .timelinePreview, cameras: [livingRoom], loaded: events)
    }
}
