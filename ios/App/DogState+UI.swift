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
