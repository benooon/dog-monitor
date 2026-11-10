/// What a device does in the household (SPEC §2). Raw values are persisted and sent to the backend.
public enum DeviceRole: String, Codable, Sendable, CaseIterable, Hashable {
    case camera
    case viewer
}
