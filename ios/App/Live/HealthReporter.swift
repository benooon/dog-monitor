import DogMonitorCore
import Foundation
import Network
import UIKit

/// Reads the camera device's health for heartbeats (SPEC §6 Health).
@MainActor
final class HealthReporter {
    private let monitor = NWPathMonitor()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        monitor.start(queue: DispatchQueue(label: "com.benooon.dogmonitor.network"))
    }

    func current(now: Date = .now) -> CameraHealth {
        let device = UIDevice.current
        let level = device.batteryLevel // -1 when unknown (e.g. simulator)
        return CameraHealth(
            batteryLevel: level < 0 ? nil : Double(level),
            isCharging: device.batteryState == .charging || device.batteryState == .full,
            thermalState: Self.thermal(ProcessInfo.processInfo.thermalState),
            network: Self.network(monitor.currentPath),
            reportedAt: now
        )
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> CameraHealth.ThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }

    private static func network(_ path: NWPath) -> CameraHealth.Network {
        guard path.status == .satisfied else { return .none }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .wifi
    }
}
