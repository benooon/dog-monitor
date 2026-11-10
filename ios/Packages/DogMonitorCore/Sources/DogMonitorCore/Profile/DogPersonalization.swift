/// Turns the "Meet your dog" answers into real settings: which dog alerts are on, and the
/// promises shown on the summary screen ("Here's how we'll watch Rex"). Pure, so the iOS flow
/// only renders it and saves the result through `/notification-prefs`.
public struct DogPersonalization: Hashable, Sendable {
    public var lifeStage: DogLifeStage?
    public var traits: Set<DogTrait>
    public var alertStyle: DogAlertStyle

    /// Dog events the onboarding decides about. Camera health and the daily summary keep their
    /// defaults: they are about the phone and the day, not the dog's personality.
    public static let dogEventTypes: [EventType] = [
        .prolongedBarking, .whining, .atDoor, .forbiddenZone, .notVisible, .calmedDown,
    ]

    public init(lifeStage: DogLifeStage? = nil, traits: Set<DogTrait> = [], alertStyle: DogAlertStyle = .balanced) {
        self.lifeStage = lifeStage
        self.traits = traits
        self.alertStyle = alertStyle
    }

    public init(_ dog: DogDTO) {
        self.init(lifeStage: dog.lifeStage, traits: Set(dog.traits), alertStyle: dog.alertStyle ?? .balanced)
    }

    /// Whether each dog event should notify the owner.
    public var alerts: [EventType: Bool] {
        var result: [EventType: Bool] = [:]
        for type in Self.dogEventTypes {
            result[type] = isAlertOn(type)
        }
        return result
    }

    public func isAlertOn(_ type: EventType) -> Bool {
        switch type {
        // Long barking and whining are why people get a dog camera: always on.
        case .prolongedBarking, .whining:
            return true
        case .atDoor:
            return alertStyle == .everything || (alertStyle == .balanced && traits.contains(.waitsAtDoor))
        case .forbiddenZone:
            return alertStyle == .everything || (alertStyle == .balanced && traits.contains(.getsOnFurniture))
        case .notVisible:
            return alertStyle == .everything
        case .calmedDown:
            return alertStyle != .important
        case .cameraOffline, .lowBattery, .overheating, .dailySummary:
            return type.isEnabledByDefault
        }
    }

    /// Applies the dog alerts to the owner's notification settings (household level; camera
    /// overrides and quiet hours stay as they are).
    public func apply(to settings: inout NotificationSettings) {
        for (type, isOn) in alerts {
            settings.setEnabled(isOn, for: type)
        }
    }

    /// One line on the summary screen, in display order. The app turns each into copy with the
    /// dog's name.
    public enum Promise: Hashable, Sendable {
        /// Long barking (and whining) alerts.
        case barking
        /// Whining or howling, called out when the owner said the dog whines.
        case whining
        case atDoor
        /// Furniture alerts are on, but they need a no-go zone drawn on the camera first.
        case furniture(needsZone: Bool)
        case calmedDown
        /// A sleepy dog with few alerts: we stay quiet unless something changes.
        case quietWhenSleeping
        /// Puppies: the daily summary helps follow how they settle in.
        case puppyProgress
        /// Every evening, a short summary of the day.
        case dailySummary
    }

    /// What we will do for this dog, most important first. `hasZones`: whether any camera
    /// already has a forbidden zone drawn.
    public func promises(hasZones: Bool = false) -> [Promise] {
        var lines: [Promise] = [.barking]
        if traits.contains(.whines) {
            lines.append(.whining)
        }
        if isAlertOn(.atDoor) {
            lines.append(.atDoor)
        }
        if isAlertOn(.forbiddenZone) {
            lines.append(.furniture(needsZone: !hasZones))
        }
        if isAlertOn(.calmedDown) {
            lines.append(.calmedDown)
        }
        if traits.contains(.mostlySleeps) && alertStyle != .everything {
            lines.append(.quietWhenSleeping)
        }
        if lifeStage == .puppy {
            lines.append(.puppyProgress)
        }
        lines.append(.dailySummary)
        return lines
    }

    /// The input to save on the dog (`POST /dogs` or `PATCH /dogs/:id`).
    public func dogInput(name: String? = nil) -> DogInput {
        DogInput(
            name: name,
            lifeStage: lifeStage,
            traits: DogTrait.allCases.filter(traits.contains),
            alertStyle: alertStyle
        )
    }
}
