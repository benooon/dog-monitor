import DogMonitorCore
import Foundation
import Observation

/// Loads a household's daily summaries (`GET /summaries`) and tracks which camera and day are shown.
@MainActor
@Observable
final class DailySummaryModel {
    enum Phase: Equatable {
        case loading, ready, failed
    }

    /// How far back the screen looks (two weeks gives a full week chart for last week's days too).
    static let daysLoaded = 14

    private(set) var phase: Phase = .loading
    let cameras: [DeviceDTO]
    var cameraId: UUID? {
        didSet { if cameraId != oldValue { selectedDate = nil } }
    }
    /// "YYYY-MM-DD"; nil shows the newest day.
    var selectedDate: String?

    private(set) var summaries: [DailySummaryDTO] = []
    private let api: DogMonitorAPI

    init(api: DogMonitorAPI, cameras: [DeviceDTO], cameraId: UUID? = nil, loaded: [DailySummaryDTO]? = nil) {
        self.api = api
        self.cameras = cameras
        self.cameraId = cameraId ?? cameras.first?.id
        if let loaded {
            summaries = loaded
            phase = .ready
        }
    }

    private var cameraSummaries: [DailySummaryDTO] {
        summaries.filter { $0.cameraId == cameraId }
    }

    var insights: DailySummaryInsights {
        DailySummaryInsights(summaries: cameraSummaries, selectedDate: selectedDate)
    }

    /// Days with a summary for the chosen camera, newest first.
    var dates: [String] {
        DailySummaryInsights.dates(in: cameraSummaries)
    }

    var cameraName: String? {
        cameras.first { $0.id == cameraId }?.name
    }

    /// Loads every camera's recent days in one request, so switching cameras is instant.
    func load(now: Date = .now, calendar: Calendar = .current) async {
        if summaries.isEmpty { phase = .loading }
        // No `to`: a camera in a time zone ahead of this phone may already be on tomorrow.
        let range = DailySummaryInsights.range(lastDays: Self.daysLoaded, now: now, calendar: calendar)
        do {
            summaries = try await api.summaries(from: range.from)
            phase = .ready
        } catch {
            if summaries.isEmpty { phase = .failed }
        }
    }
}
