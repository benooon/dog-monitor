/// What the owner told us about the dog in "Meet your dog". Raw values are the wire format
/// shared with the backend (`backend/src/db/schema.ts`: DOG_LIFE_STAGES, DOG_TRAITS, DOG_ALERT_STYLES).
public enum DogLifeStage: String, Codable, Sendable, CaseIterable, Hashable {
    case puppy, adult, senior
}

/// Things the dog tends to do when alone. Several can apply.
public enum DogTrait: String, Codable, Sendable, CaseIterable, Hashable {
    case barksAtNoises
    case whines
    case waitsAtDoor
    case getsOnFurniture
    case mostlySleeps
}

/// How many alerts the owner wants about the dog.
public enum DogAlertStyle: String, Codable, Sendable, CaseIterable, Hashable {
    /// Only barking that goes on and distress.
    case important
    /// Also what this dog tends to do (door, furniture) and when it settles down.
    case balanced
    /// Every dog event.
    case everything
}
