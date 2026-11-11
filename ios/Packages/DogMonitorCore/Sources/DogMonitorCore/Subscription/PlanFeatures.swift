import Foundation

/// What each plan includes, in one place. Mirrors `PLAN_FEATURES` in `backend/src/billing/plans.ts`;
/// the server enforces it, the app uses it for copy (paywall, upsells) and to hide what a plan lacks.
///
/// Dog alerts (sofa, door, barking, whining) are free on every plan, so they are not listed here.
public struct PlanFeatures: Sendable, Hashable {
    /// Active cameras the household may pair.
    public let cameras: Int
    /// People in the household, owner included. Nil: everyone (up to the household cap of 6).
    public let members: Int?
    /// Days a clip or snapshot is kept.
    public let clipRetentionDays: Int
    /// Week-over-week trends and the vet PDF.
    public let insights: Bool
    /// The daily highlight reel.
    public let highlightReel: Bool

    public static let free = PlanFeatures(cameras: 1, members: 2, clipRetentionDays: 1, insights: false, highlightReel: false)
    public static let premium = PlanFeatures(cameras: 4, members: nil, clipRetentionDays: 30, insights: true, highlightReel: true)

    public static func `for`(_ plan: HouseholdPlan) -> PlanFeatures {
        switch plan {
        case .free: .free
        case .premium: .premium
        }
    }

    /// Whether a clip that started at `startedAt` is still kept on this plan at `now`.
    public func keepsClip(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) < TimeInterval(clipRetentionDays) * 24 * 60 * 60
    }
}
