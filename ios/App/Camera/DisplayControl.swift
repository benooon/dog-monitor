import UIKit

/// Screen settings camera mode changes while it runs: auto-lock and brightness (SPEC §7).
@MainActor
enum DisplayControl {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
    }

    static var brightness: Double? {
        screen.map { Double($0.brightness) }
    }

    static func setBrightness(_ value: Double) {
        screen?.brightness = CGFloat(min(max(value, 0), 1))
    }

    static func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}
