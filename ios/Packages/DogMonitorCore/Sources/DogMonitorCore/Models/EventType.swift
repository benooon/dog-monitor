/// Kinds of events that can be stored in the timeline and pushed (SPEC §5).
/// Raw values are the wire format shared with the backend.
public enum EventType: String, Codable, Sendable, CaseIterable, Hashable {
    case prolongedBarking
    case whining
    case forbiddenZone
    case atDoor
    case notVisible
    case calmedDown
    case cameraOffline
    case lowBattery
    case overheating
    case dailySummary

    public enum InterruptionLevel: String, Codable, Sendable {
        case passive, active, timeSensitive
    }

    /// Whether viewers receive this push unless they turn it off.
    public var isEnabledByDefault: Bool {
        switch self {
        case .forbiddenZone, .atDoor, .notVisible: false
        default: true
        }
    }

    public var interruptionLevel: InterruptionLevel {
        switch self {
        case .prolongedBarking, .whining, .cameraOffline, .lowBattery, .overheating: .timeSensitive
        case .forbiddenZone, .atDoor, .notVisible: .active
        case .calmedDown, .dailySummary: .passive
        }
    }

    /// The dog state this event reports, if it is a dog-state event.
    public var dogState: DogState? {
        switch self {
        case .prolongedBarking: .barking
        case .whining: .whining
        case .forbiddenZone: .forbiddenZone
        case .atDoor: .atDoor
        case .notVisible: .notVisible
        case .calmedDown: .resting
        case .cameraOffline, .lowBattery, .overheating, .dailySummary: nil
        }
    }
}
