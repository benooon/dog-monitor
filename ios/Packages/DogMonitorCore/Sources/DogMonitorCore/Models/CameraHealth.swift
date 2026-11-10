import Foundation

/// Camera device health, sent with each heartbeat (SPEC §6 Health).
public struct CameraHealth: Codable, Sendable, Hashable {
    /// Mirrors `ProcessInfo.ThermalState` without depending on it.
    public enum ThermalState: String, Codable, Sendable, CaseIterable, Comparable {
        case nominal, fair, serious, critical

        private var rank: Int {
            switch self {
            case .nominal: 0
            case .fair: 1
            case .serious: 2
            case .critical: 3
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    public enum Network: String, Codable, Sendable, CaseIterable {
        case wifi, cellular, wired, none
    }

    public enum Warning: String, Codable, Sendable, CaseIterable, Hashable {
        case unplugged, lowBattery, overheating, offline
    }

    /// Battery level in 0...1, or nil if unknown (e.g. simulator).
    public var batteryLevel: Double?
    public var isCharging: Bool
    public var thermalState: ThermalState
    public var network: Network
    public var reportedAt: Date

    public init(batteryLevel: Double?, isCharging: Bool, thermalState: ThermalState, network: Network, reportedAt: Date) {
        self.batteryLevel = batteryLevel.map { min(max($0, 0), 1) }
        self.isCharging = isCharging
        self.thermalState = thermalState
        self.network = network
        self.reportedAt = reportedAt
    }

    public static let lowBatteryThreshold = 0.2

    /// Warnings to surface on the camera screen and to viewers (SPEC §7).
    public var warnings: Set<Warning> {
        var result: Set<Warning> = []
        if !isCharging { result.insert(.unplugged) }
        if let batteryLevel, batteryLevel < Self.lowBatteryThreshold { result.insert(.lowBattery) }
        if thermalState >= .serious { result.insert(.overheating) }
        if network == .none { result.insert(.offline) }
        return result
    }
}
