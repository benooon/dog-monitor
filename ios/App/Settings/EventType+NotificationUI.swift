import DogMonitorCore
import SwiftUI

extension EventType {
    /// Row title in notification settings.
    var notificationTitle: LocalizedStringKey {
        switch self {
        case .prolongedBarking: "Long barking"
        case .whining: "Whining or howling"
        case .forbiddenZone: "In a forbidden zone"
        case .atDoor: "Waiting at the door"
        case .notVisible: "Out of view"
        case .calmedDown: "Calmed down"
        case .cameraOffline: "Camera offline"
        case .lowBattery: "Low battery"
        case .overheating: "Camera too hot"
        case .dailySummary: "Daily summary"
        }
    }

    var notificationSymbol: String {
        switch self {
        case .prolongedBarking: "speaker.wave.3.fill"
        case .whining: "waveform"
        case .forbiddenZone: "nosign"
        case .atDoor: "door.left.hand.closed"
        case .notVisible: "eye.slash"
        case .calmedDown: "moon.zzz"
        case .cameraOffline: "video.slash"
        case .lowBattery: "battery.25"
        case .overheating: "thermometer.high"
        case .dailySummary: "chart.bar"
        }
    }
}

extension NotificationSettings.Group {
    /// Section header; the dog section uses the dog's name when we know it.
    func header(dogName: String?) -> Text {
        switch self {
        case .dog: dogName.map { Text(verbatim: $0) } ?? Text("Your dog")
        case .camera: Text("Camera health")
        case .summary: Text("Summary")
        }
    }
}
