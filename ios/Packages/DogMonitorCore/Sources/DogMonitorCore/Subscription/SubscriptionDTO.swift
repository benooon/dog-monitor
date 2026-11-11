import Foundation

/// The household's plan. Unknown values from a newer server read as `.free`.
public enum HouseholdPlan: String, Codable, Sendable, Hashable {
    case free, premium

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HouseholdPlan(rawValue: raw) ?? .free
    }
}

/// `GET /subscription` and `POST /subscription/apple`: plan, limits and usage for the household.
public struct SubscriptionDTO: Codable, Sendable, Hashable {
    public struct Counts: Codable, Sendable, Hashable {
        public let cameras: Int
        /// People in the household, owner included (nil from an older server).
        public let members: Int?

        public init(cameras: Int, members: Int? = nil) {
            self.cameras = cameras
            self.members = members
        }
    }

    public let plan: HouseholdPlan
    /// When premium ends unless it renews (nil on the free plan and for Lifetime Premium).
    public let expiresAt: Date?
    /// Premium bought once, for good (nil from an older server).
    public let lifetime: Bool?
    public let productId: String?
    public let limits: Counts
    public let usage: Counts

    public init(
        plan: HouseholdPlan,
        expiresAt: Date?,
        lifetime: Bool? = nil,
        productId: String?,
        limits: Counts,
        usage: Counts
    ) {
        self.plan = plan
        self.expiresAt = expiresAt
        self.lifetime = lifetime
        self.productId = productId
        self.limits = limits
        self.usage = usage
    }

    public var isPremium: Bool { plan == .premium }

    /// Premium that never ends: no renewal date, nothing to manage or cancel.
    public var isLifetime: Bool { isPremium && lifetime == true }

    /// What the household's plan includes.
    public var features: PlanFeatures { .for(plan) }

    /// How many more cameras the household can pair.
    public var camerasLeft: Int { max(0, limits.cameras - usage.cameras) }

    public var canPairCamera: Bool { camerasLeft > 0 }

    /// The free plan is what stops another camera, so Premium would help.
    public var suggestsUpgrade: Bool { plan == .free && !canPairCamera }
}
