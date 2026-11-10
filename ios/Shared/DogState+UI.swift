import DogMonitorCore
import SwiftUI

extension DogState {
    /// Short label for indicators; nil when there is nothing to show yet.
    var label: LocalizedStringKey? {
        switch self {
        case .resting: "Resting"
        case .barking: "Barking"
        case .whining: "Whining"
        case .restless: "Restless"
        case .atDoor: "At the door"
        case .forbiddenZone: "In a forbidden zone"
        case .notVisible: "Not visible"
        case .unknown: nil
        }
    }
}

extension DogState {
    /// SF Symbol for compact indicators (Dynamic Island, widgets).
    var symbol: String {
        switch self {
        case .resting: "moon.zzz.fill"
        case .barking: "speaker.wave.3.fill"
        case .whining: "waveform"
        case .restless: "pawprint.fill"
        case .atDoor: "door.left.hand.closed"
        case .forbiddenZone: "nosign"
        case .notVisible: "eye.slash"
        case .unknown: "pawprint"
        }
    }
}
