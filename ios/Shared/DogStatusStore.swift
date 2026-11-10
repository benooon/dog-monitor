import DogMonitorCore
import Foundation

/// The app group both the app and the widget extension can read. Only shared on a device once
/// the App Groups capability is enabled for both App IDs (docs/HUMAN_TODO.md); until then the
/// widget shows its "open the app" state.
enum DogStatusStore {
    static let appGroup = "group.com.benooon.dogmonitor"
    static let widgetKind = "DogStatusWidget"
    private static let key = "dogStatusSnapshots"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func load() -> [DogStatusSnapshot] {
        DogStatusSnapshot.decode(defaults?.data(forKey: key))
    }

    static func save(_ snapshots: [DogStatusSnapshot]) {
        guard let data = try? DogStatusSnapshot.encode(snapshots) else { return }
        defaults?.set(data, forKey: key)
    }
}
