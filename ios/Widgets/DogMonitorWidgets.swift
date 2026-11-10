import SwiftUI
import WidgetKit

@main
struct DogMonitorWidgets: WidgetBundle {
    var body: some Widget {
        DogStatusWidget()
        CameraLiveActivityWidget()
    }
}
