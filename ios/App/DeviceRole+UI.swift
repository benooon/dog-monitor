import DogMonitorCore
import SwiftUI

extension DeviceRole {
    var title: LocalizedStringKey {
        switch self {
        case .camera: "Camera"
        case .viewer: "Viewer"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .camera: "Leave this phone at home to watch your dog."
        case .viewer: "Watch live and get alerts on your own phone."
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "video.fill"
        case .viewer: "iphone"
        }
    }
}
