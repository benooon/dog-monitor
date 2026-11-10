import Foundation

/// A dog body-pose joint in normalized image coordinates (origin top-left), mirroring the joints
/// Vision's animal body pose reports, without depending on Vision.
public struct PoseJoint: Sendable, Hashable {
    public enum Name: String, Sendable, CaseIterable, Hashable {
        case nose, neck, tailTop
        case leftFrontElbow, rightFrontElbow, leftFrontKnee, rightFrontKnee, leftFrontPaw, rightFrontPaw
        case leftBackElbow, rightBackElbow, leftBackKnee, rightBackKnee, leftBackPaw, rightBackPaw
    }

    public var name: Name
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(name: Name, x: Double, y: Double, confidence: Double) {
        self.name = name
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

/// Lying or standing, from where the paws sit relative to the body (SPEC §4 layer 2).
public enum DogPosture: String, Sendable, Hashable {
    case lying, standing

    /// Joints below this confidence are ignored.
    public static let minimumConfidence = 0.3

    /// Standing when the paws are well below the body line (neck to tail), by more than
    /// `legRatio` of the body length; lying when legs are folded or stretched sideways.
    /// Returns nil when too few joints are visible to tell.
    public static func classify(_ joints: [PoseJoint], legRatio: Double = 0.35) -> DogPosture? {
        let visible = Dictionary(
            joints.filter { $0.confidence >= minimumConfidence }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let neck = visible[.neck], let tail = visible[.tailTop] else { return nil }
        let bodyLength = hypot(neck.x - tail.x, neck.y - tail.y)
        guard bodyLength > 0.02 else { return nil }

        let paws: [PoseJoint.Name] = [.leftFrontPaw, .rightFrontPaw, .leftBackPaw, .rightBackPaw]
        let pawYs = paws.compactMap { visible[$0]?.y }
        guard pawYs.count >= 2 else { return nil }
        let bodyY = (neck.y + tail.y) / 2
        let pawY = pawYs.reduce(0, +) / Double(pawYs.count)
        // y grows downward: standing paws are much lower than the body.
        return (pawY - bodyY) > legRatio * bodyLength ? .standing : .lying
    }

    public var detectionKind: Detection.Kind {
        switch self {
        case .lying: .dogLying
        case .standing: .dogStanding
        }
    }
}
