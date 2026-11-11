import DogMonitorCore
import SwiftUI

extension EventDTO {
    /// Title in the timeline and on the event screen. Off-limits events say "on the sofa" when the
    /// backend knows it was the sofa (`place`).
    var timelineTitle: LocalizedStringKey {
        guard type == .forbiddenZone else { return type.notificationTitle }
        return isOnSofa ? "On the sofa" : "Somewhere off-limits"
    }

    var timelineSymbol: String {
        isOnSofa ? "sofa.fill" : type.notificationSymbol
    }
}
