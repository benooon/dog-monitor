import Foundation

/// The door and off-limits (sofa or forbidden) zones the classifier checks the dog's position against.
public struct DogZones: Codable, Sendable, Hashable {
    public var door: [ZonePolygon]
    public var forbidden: [ZonePolygon]

    public init(door: [ZonePolygon] = [], forbidden: [ZonePolygon] = []) {
        self.door = door
        self.forbidden = forbidden
    }

    /// From the zones drawn in camera setup; bed zones don't affect the state (yet).
    public init(_ zones: [CameraZone]) {
        door = zones.filter { $0.kind == .door }.map(\.polygon)
        forbidden = zones.filter(\.kind.isOffLimits).map(\.polygon)
    }
}

public struct DogStateClassifierConfiguration: Sendable, Hashable {
    /// Lying with little motion this long means resting (SPEC §4: 2+ min).
    public var restingAfter: TimeInterval
    /// Motion is judged over this window for "restless".
    public var motionWindow: TimeInterval
    /// Fraction of motion samples in the window that makes the dog restless.
    public var restlessMotionFraction: Double
    /// Fewer samples than this in the window can't show continuous motion.
    public var minimumMotionSamples: Int
    /// Fraction of motion samples a resting dog may have (twitches, breathing, light).
    public var restingMotionFraction: Double

    public init(
        restingAfter: TimeInterval = 120,
        motionWindow: TimeInterval = 30,
        restlessMotionFraction: Double = 0.6,
        minimumMotionSamples: Int = 8,
        restingMotionFraction: Double = 0.2
    ) {
        self.restingAfter = restingAfter
        self.motionWindow = motionWindow
        self.restlessMotionFraction = restlessMotionFraction
        self.minimumMotionSamples = minimumMotionSamples
        self.restingMotionFraction = restingMotionFraction
    }
}

/// Rule-based visual state (SPEC §4 layer 3): where the dog is, its posture, and motion over time
/// → resting / restless / atDoor / forbiddenZone / notVisible, or `.unknown` when nothing stands
/// out. Durations for door, forbidden zone and not-visible events are the event engine's job;
/// feed each result to `EventEngine.observe(_:at:)`. Pure: time comes from the inputs.
public struct DogStateClassifier: Sendable {
    public var zones: DogZones
    public let configuration: DogStateClassifierConfiguration
    private var motionSamples: [(time: Date, moving: Bool)] = []
    private var lyingSince: Date?

    public init(zones: DogZones = DogZones(), configuration: DogStateClassifierConfiguration = DogStateClassifierConfiguration()) {
        self.zones = zones
        self.configuration = configuration
    }

    /// Records one motion-detector result (every analyzed frame, 2–5 per second).
    public mutating func noteMotion(_ moving: Bool, at time: Date) {
        motionSamples.append((time, moving))
        let cutoff = time.addingTimeInterval(-configuration.motionWindow)
        if let firstKept = motionSamples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            motionSamples.removeFirst(firstKept)
        }
    }

    /// Classifies one Vision result: the `.dogVisible` / `.dogLying` / `.dogStanding` detections
    /// seen at `time` (empty when no dog was found).
    public mutating func classify(_ detections: [Detection], at time: Date) -> DogState {
        guard let dog = detections.first(where: { $0.kind == .dogVisible }) else {
            lyingSince = nil
            return .notVisible
        }
        if let box = dog.boundingBox {
            let center = (x: box.midX, y: box.midY)
            if zones.forbidden.contains(where: { $0.contains(x: center.x, y: center.y) }) { return .forbiddenZone }
            if zones.door.contains(where: { $0.contains(x: center.x, y: center.y) }) { return .atDoor }
        }

        let motion = motionFraction(at: time)
        let lying = detections.contains { $0.kind == .dogLying }
        if lying, motion.fraction <= configuration.restingMotionFraction {
            if lyingSince == nil { lyingSince = time }
        } else {
            lyingSince = nil
        }
        if let lyingSince, time.timeIntervalSince(lyingSince) >= configuration.restingAfter {
            return .resting
        }
        if motion.samples >= configuration.minimumMotionSamples, motion.fraction >= configuration.restlessMotionFraction, !lying {
            return .restless
        }
        return .unknown
    }

    private func motionFraction(at time: Date) -> (fraction: Double, samples: Int) {
        let cutoff = time.addingTimeInterval(-configuration.motionWindow)
        let recent = motionSamples.filter { $0.time >= cutoff && $0.time <= time }
        guard !recent.isEmpty else { return (0, 0) }
        let moving = recent.filter { $0.moving }.count
        return (Double(moving) / Double(recent.count), recent.count)
    }

}
