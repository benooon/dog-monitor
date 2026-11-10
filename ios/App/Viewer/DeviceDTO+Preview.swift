import DogMonitorCore
import Foundation

extension DeviceDTO {
    /// A sample online camera with a resting dog, for previews.
    static var previewCamera: DeviceDTO {
        DeviceDTO(
            id: UUID(),
            householdId: UUID(),
            name: "Living room",
            role: .camera,
            lastHeartbeatAt: .now,
            battery: 0.8,
            charging: true,
            dogState: DogState.resting.rawValue,
            createdAt: .now
        )
    }
}
