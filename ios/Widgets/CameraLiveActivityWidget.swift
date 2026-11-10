import ActivityKit
import DogMonitorCore
import SwiftUI
import UIKit
import WidgetKit

/// The dog's state and the camera's status on the Lock Screen and in the Dynamic Island.
/// The backend keeps it current with `liveactivity` pushes.
struct CameraLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CameraActivityAttributes.self) { context in
            LiveActivityLockScreenView(attributes: context.attributes, content: context.state, photo: SharedDogPhoto.image())
        } dynamicIsland: { context in
            let attributes = context.attributes
            let content = context.state
            let photo = SharedDogPhoto.image()
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DogFace(photo: photo, symbol: content.displayState.symbol, tint: content.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        content.statusText
                            .font(.subheadline)
                        Text(verbatim: attributes.cameraName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                if let photo {
                    DogPhotoCircle(photo: photo)
                } else {
                    Image(systemName: "pawprint.fill")
                        .accessibilityHidden(true)
                }
            } compactTrailing: {
                Image(systemName: content.displayState.symbol)
                    .foregroundStyle(content.tint)
                    .accessibilityLabel(content.statusText)
            } minimal: {
                Image(systemName: content.displayState.symbol)
                    .foregroundStyle(content.tint)
                    .accessibilityLabel(content.statusText)
            }
            .keylineTint(content.tint)
        }
    }
}

/// Lock Screen banner: the dog's name, what it's doing, and which camera is watching.
struct LiveActivityLockScreenView: View {
    let attributes: CameraActivityAttributes
    let content: CameraLiveActivityContent
    /// The dog's face from the app group; nil shows the state symbol instead.
    var photo: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            DogFace(photo: photo, symbol: content.displayState.symbol, tint: content.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: attributes.title)
                    .font(.headline)
                content.statusText
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label {
                Text(verbatim: attributes.cameraName)
            } icon: {
                Image(systemName: content.online ? "video.fill" : "video.slash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

extension CameraActivityAttributes {
    /// "Rex", or the camera's name when the household has no dog yet.
    var title: String { dogName ?? cameraName }
}

extension CameraLiveActivityContent {
    /// "Resting", "Camera offline", or "Watching" before the camera knows.
    var statusText: Text {
        if !online { return Text("Camera offline") }
        if let label = displayState.label { return Text(label) }
        return Text("Watching")
    }

    /// Orange when the dog needs a look or the camera is offline, otherwise the accent.
    var tint: Color {
        needsAttention ? .orange : .accentColor
    }
}

#Preview("Lock Screen", as: .content, using: CameraActivityAttributes.preview) {
    CameraLiveActivityWidget()
} contentStates: {
    CameraLiveActivityContent(state: .resting, online: true)
    CameraLiveActivityContent(state: .barking, online: true)
    CameraLiveActivityContent(state: nil, online: false)
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: CameraActivityAttributes.preview) {
    CameraLiveActivityWidget()
} contentStates: {
    CameraLiveActivityContent(state: .atDoor, online: true)
}

extension CameraActivityAttributes {
    static var preview: CameraActivityAttributes {
        CameraActivityAttributes(cameraId: UUID(), cameraName: "Living room", dogName: "Rex")
    }
}
