import Foundation

/// One camera's day, in the camera's local time (SPEC §8 daily summary). Wire format of
/// `PUT /device/summaries/:date` and `GET /summaries`.
public struct DailySummary: Codable, Sendable, Hashable {
    /// "YYYY-MM-DD" in the camera's time zone.
    public var date: String
    public var restMinutes: Int
    public var barkCount: Int
    /// 24 values, one per local hour: minutes with motion.
    public var activityByHour: [Int]
    /// Minutes in each dog state, keyed by `DogState` raw value.
    public var stateMinutes: [String: Int]

    public init(date: String, restMinutes: Int = 0, barkCount: Int = 0, activityByHour: [Int] = Array(repeating: 0, count: 24), stateMinutes: [String: Int] = [:]) {
        self.date = date
        self.restMinutes = restMinutes
        self.barkCount = barkCount
        self.activityByHour = activityByHour
        self.stateMinutes = stateMinutes
    }

    public func minutes(in state: DogState) -> Int {
        stateMinutes[state.rawValue] ?? 0
    }

    /// The local hour with the most activity, if any.
    public var busiestHour: Int? {
        guard let peak = activityByHour.max(), peak > 0 else { return nil }
        return activityByHour.firstIndex(of: peak)
    }
}

/// What the backend returns for a stored day.
public struct DailySummaryDTO: Codable, Sendable, Hashable, Identifiable {
    public let cameraId: UUID
    public let date: String
    public let restMinutes: Int
    public let barkCount: Int
    public let activityByHour: [Int]
    public let stateMinutes: [String: Int]
    public let isFinal: Bool
    /// The day's highlight reel is uploaded (nil from an older server).
    public let hasReel: Bool?

    public init(
        cameraId: UUID,
        date: String,
        restMinutes: Int,
        barkCount: Int,
        activityByHour: [Int],
        stateMinutes: [String: Int],
        isFinal: Bool,
        hasReel: Bool? = nil
    ) {
        self.hasReel = hasReel
        self.cameraId = cameraId
        self.date = date
        self.restMinutes = restMinutes
        self.barkCount = barkCount
        self.activityByHour = activityByHour
        self.stateMinutes = stateMinutes
        self.isFinal = isFinal
    }

    public var id: String { "\(cameraId.uuidString)-\(date)" }

    public var summary: DailySummary {
        DailySummary(date: date, restMinutes: restMinutes, barkCount: barkCount, activityByHour: activityByHour, stateMinutes: stateMinutes)
    }
}

struct DailySummaryUpload: Encodable {
    var restMinutes: Int
    var barkCount: Int
    var activityByHour: [Int]
    var stateMinutes: [String: Int]
    var final: Bool
}

/// `GET /summaries/:cameraId/:date/reel`: a short-lived download URL for the day's reel.
public struct ReelMediaDTO: Codable, Sendable, Hashable {
    public let url: URL
    public let expiresAt: Date

    public init(url: URL, expiresAt: Date) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

struct ReelUploadDTO: Decodable {
    var upload: PresignedUploadDTO
}

struct ReelAttachedDTO: Decodable {
    var hasReel: Bool
}

struct DailySummaryList: Decodable {
    var summaries: [DailySummaryDTO]
}

/// Builds daily summaries on the camera from a once-a-second tick (current state + motion) and
/// bark detections. Time is split into local days and hours with the injected calendar, so it is
/// testable and handles midnight. Codable so the camera can persist it across restarts.
public struct DailySummaryAccumulator: Codable, Sendable {
    /// Gaps longer than this between ticks (app suspended, camera off) are not counted.
    public static let maxTickGap: TimeInterval = 5

    private struct Day: Codable, Sendable {
        var seconds: [String: Double] = [:]
        var activeSeconds: [Double] = Array(repeating: 0, count: 24)
        var barks = 0
        var uploadedFinal = false
    }

    private var days: [String: Day] = [:]
    private var lastTick: Date?

    public init() {}

    /// Counts the time since the previous tick toward `state` (and toward activity if `moving`).
    public mutating func tick(state: DogState, moving: Bool, at now: Date, calendar: Calendar) {
        defer { lastTick = now }
        guard let lastTick else { return }
        let elapsed = now.timeIntervalSince(lastTick)
        guard elapsed > 0, elapsed <= Self.maxTickGap else { return }
        let key = Self.dateKey(now, calendar: calendar)
        let hour = calendar.component(.hour, from: now)
        if days[key] == nil { prune(before: now, calendar: calendar) }
        var day = days[key] ?? Day()
        day.seconds[state.rawValue, default: 0] += elapsed
        if moving, (0..<24).contains(hour) { day.activeSeconds[hour] += elapsed }
        days[key] = day
    }

    public mutating func noteBark(at time: Date, calendar: Calendar) {
        let key = Self.dateKey(time, calendar: calendar)
        days[key, default: Day()].barks += 1
    }

    /// The summary of `date` so far ("YYYY-MM-DD").
    public func summary(for date: String) -> DailySummary {
        guard let day = days[date] else { return DailySummary(date: date) }
        var stateMinutes: [String: Int] = [:]
        for (state, seconds) in day.seconds where state != DogState.unknown.rawValue {
            let minutes = Int((seconds / 60).rounded())
            if minutes > 0 { stateMinutes[state] = min(minutes, 1440) }
        }
        return DailySummary(
            date: date,
            restMinutes: stateMinutes[DogState.resting.rawValue] ?? 0,
            barkCount: day.barks,
            activityByHour: day.activeSeconds.map { min(Int(($0 / 60).rounded()), 60) },
            stateMinutes: stateMinutes
        )
    }

    /// Days to upload now: past days not yet sent as final (`final == true`), then today.
    public func pendingUploads(now: Date, calendar: Calendar) -> [(summary: DailySummary, final: Bool)] {
        let today = Self.dateKey(now, calendar: calendar)
        var result = days.keys.sorted()
            .filter { $0 < today && days[$0]?.uploadedFinal == false }
            .map { (summary: summary(for: $0), final: true) }
        result.append((summary: summary(for: today), final: false))
        return result
    }

    /// Records a successful final upload.
    public mutating func markUploadedFinal(_ date: String) {
        days[date]?.uploadedFinal = true
    }

    /// Days kept on the phone (older ones are dropped, uploaded or not).
    public static let keptDays = 7

    private mutating func prune(before now: Date, calendar: Calendar) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.keptDays, to: now) else { return }
        let oldest = Self.dateKey(cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }

    /// "YYYY-MM-DD" of `date` in `calendar`'s time zone.
    public static func dateKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 0, day = parts.day ?? 0
        return "\(year)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }
}
