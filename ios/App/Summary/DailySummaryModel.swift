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

    /// How far back the screen looks: a month, for the vet report (and two full weeks to compare).
    static let daysLoaded = VetReport.days + 1
    /// Sofa visits are counted over the last two weeks (one page of the timeline is plenty).
    static let sofaVisitPage = 100

    private(set) var phase: Phase = .loading
    let cameras: [DeviceDTO]
    var cameraId: UUID? {
        didSet { if cameraId != oldValue { selectedDate = nil } }
    }
    /// "YYYY-MM-DD"; nil shows the newest day.
    var selectedDate: String?

    private(set) var summaries: [DailySummaryDTO] = []
    /// Weekly insights and the vet report (Premium); nil until the plan is known.
    private(set) var insightsUnlocked: Bool?
    /// Start times of each camera's sofa alerts over the last two weeks.
    private(set) var sofaVisits: [UUID: [Date]] = [:]
    private let api: DogMonitorAPI

    init(
        api: DogMonitorAPI,
        cameras: [DeviceDTO],
        cameraId: UUID? = nil,
        loaded: [DailySummaryDTO]? = nil,
        insightsUnlocked: Bool? = nil,
        sofaVisits: [UUID: [Date]] = [:]
    ) {
        self.api = api
        self.cameras = cameras
        self.cameraId = cameraId ?? cameras.first?.id
        self.insightsUnlocked = insightsUnlocked
        self.sofaVisits = sofaVisits
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

    /// This camera's week compared with the one before (Premium).
    func weeklyInsights(calendar: Calendar) -> WeeklyInsights {
        WeeklyInsights(summaries: cameraSummaries, sofaVisits: cameraId.flatMap { sofaVisits[$0] } ?? [], calendar: calendar)
    }

    /// This camera's last 30 finished days, for "Share with your vet" (Premium).
    var vetReport: VetReport {
        VetReport(summaries: cameraSummaries)
    }

    /// The stored day on display, for its highlight reel.
    var selectedSummary: DailySummaryDTO? {
        guard let date = insights.day?.date else { return nil }
        return cameraSummaries.first { $0.date == date }
    }

    /// Downloads a day's highlight reel to a local file, so it plays smoothly and can be shared
    /// as a video (a link would expire in minutes).
    func reelFile(for summary: DailySummaryDTO) async throws -> URL {
        let file = Self.reelCacheURL(for: summary)
        let folder = file.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let media = try await api.reel(cameraId: summary.cameraId, date: summary.date)
        let (downloaded, response) = try await URLSession.shared.download(from: media.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: downloaded, to: file)
        return file
    }

    /// Where a day's downloaded reel is kept on this phone.
    nonisolated static func reelCacheURL(for summary: DailySummaryDTO) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reels", isDirectory: true)
            .appendingPathComponent("\(summary.cameraId.uuidString)-\(summary.date).mp4")
    }

    var cameraName: String? {
        cameras.first { $0.id == cameraId }?.name
    }

    /// Loads every camera's recent days in one request, so switching cameras is instant.
    func load(now: Date = .now, calendar: Calendar = .current) async {
        if summaries.isEmpty { phase = .loading }
        // No `to`: a camera in a time zone ahead of this phone may already be on tomorrow.
        let range = DailySummaryInsights.range(lastDays: Self.daysLoaded, now: now, calendar: calendar)
        // The plan and sofa visits only add the weekly section; the summary shows without them.
        let api = self.api
        let sofaLimit = Self.sofaVisitPage
        async let plan = try? api.subscription()
        async let sofa = try? api.timeline(TimelineFilter(types: [.forbiddenZone]), limit: sofaLimit)
        do {
            summaries = try await api.summaries(from: range.from)
            phase = .ready
        } catch {
            if summaries.isEmpty { phase = .failed }
        }
        if let status = await plan {
            insightsUnlocked = status.insightsUnlocked
        }
        if let page = await sofa {
            sofaVisits = Self.sofaVisits(in: page.events)
        }
    }

    /// Sofa alerts grouped by camera.
    nonisolated static func sofaVisits(in events: [EventDTO]) -> [UUID: [Date]] {
        var visits: [UUID: [Date]] = [:]
        for event in events where event.type == .forbiddenZone && event.place == "sofa" {
            guard let camera = event.cameraId else { continue }
            visits[camera, default: []].append(event.startedAt)
        }
        return visits
    }
}
