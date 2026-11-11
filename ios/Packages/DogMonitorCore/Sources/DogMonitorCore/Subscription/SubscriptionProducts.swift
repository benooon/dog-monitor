import Foundation

/// App Store product ids for Premium. Keep in sync with `APP_STORE_PRODUCT_IDS` on the backend.
public enum SubscriptionProducts {
    public static let yearly = "com.benooon.dogmonitor.premium.yearly"
    public static let monthly = "com.benooon.dogmonitor.premium.monthly"

    /// Display order: yearly first.
    public static let all = [yearly, monthly]

    /// Cameras a Premium household can pair (`PLAN_LIMITS.premium` on the backend), for marketing copy.
    /// Screens that check a real limit read `SubscriptionDTO.limits` instead.
    public static let premiumCameraLimit = 4

    /// Puts App Store products in display order (yearly first); the App Store returns them unordered.
    /// Ids that aren't Premium plans go last, in their original order.
    public static func inDisplayOrder<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        let ranked = items.enumerated().map { offset, item in
            (rank: all.firstIndex(of: id(item)) ?? all.count, offset: offset, item: item)
        }
        return ranked
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.item)
    }

    public static func isPremium(_ productId: String) -> Bool {
        all.contains(productId)
    }
}
