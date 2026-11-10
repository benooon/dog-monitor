/// The dog's current state as inferred on the camera device (SPEC §4).
public enum DogState: String, Codable, Sendable, CaseIterable, Hashable {
    case resting
    case barking
    case whining
    case restless
    case atDoor
    case forbiddenZone
    case notVisible
    /// No classification yet (e.g. right after the camera starts).
    case unknown

    /// States that warrant attention and may produce an alert event.
    public var isAlerting: Bool {
        switch self {
        case .barking, .whining, .atDoor, .forbiddenZone, .notVisible: true
        case .resting, .restless, .unknown: false
        }
    }
}
