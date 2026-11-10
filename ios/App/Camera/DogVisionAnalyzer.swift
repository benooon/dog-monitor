@preconcurrency import AVFoundation
import DogMonitorCore
@preconcurrency import Vision

/// Finds the dog in a camera frame and reads its posture (SPEC §4 layer 2), using Vision's
/// built-in animal recognizer and animal body pose. Runs synchronously; call it off the main actor.
enum DogVisionAnalyzer {
    /// While something moves, look about twice a second.
    static let intervalWithMotion: TimeInterval = 0.5
    /// With no motion, still look now and then, so a dog that left (or lies still) is noticed.
    static let intervalWithoutMotion: TimeInterval = 10

    static func isDue(lastRun: Date?, now: Date, motion: Bool) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= (motion ? intervalWithMotion : intervalWithoutMotion)
    }

    /// `.dogVisible` (with its box) and, when the pose is clear, `.dogLying` or `.dogStanding`.
    /// Empty when no dog is in the frame.
    static func analyze(_ sample: CaptureSample, at time: Date) -> [Detection] {
        guard sample.kind == .video else { return [] }
        let animals = VNRecognizeAnimalsRequest()
        let pose = VNDetectAnimalBodyPoseRequest()
        // Frames are already rotated upright by the capture connection.
        let handler = VNImageRequestHandler(cmSampleBuffer: sample.buffer, orientation: .up)
        do {
            try handler.perform([animals, pose])
        } catch {
            return []
        }
        let dogs = (animals.results ?? []).filter { observation in
            observation.labels.contains { $0.identifier == VNAnimalIdentifier.dog.rawValue }
        }
        guard let dog = dogs.max(by: { $0.confidence < $1.confidence }) else { return [] }
        let box = normalized(dog.boundingBox)
        var detections = [Detection(kind: .dogVisible, confidence: Double(dog.confidence), timestamp: time, boundingBox: box)]
        if let observation = pose.results?.first,
           let posture = DogPosture.classify(joints(of: observation)) {
            detections.append(Detection(kind: posture.detectionKind, confidence: Double(observation.confidence), timestamp: time, boundingBox: box))
        }
        return detections
    }

    /// Vision's origin is bottom-left; ours is top-left.
    private static func normalized(_ rect: CGRect) -> CoreNormalizedRect {
        CoreNormalizedRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func joints(of observation: VNAnimalBodyPoseObservation) -> [PoseJoint] {
        guard let points = try? observation.recognizedPoints(.all) else { return [] }
        return jointNames.compactMap { visionName, name in
            guard let point = points[visionName] else { return nil }
            return PoseJoint(name: name, x: point.location.x, y: 1 - point.location.y, confidence: Double(point.confidence))
        }
    }

    private static var jointNames: [(VNAnimalBodyPoseObservation.JointName, PoseJoint.Name)] {
        [
            (.nose, .nose), (.neck, .neck), (.tailTop, .tailTop),
            (.leftFrontElbow, .leftFrontElbow), (.rightFrontElbow, .rightFrontElbow),
            (.leftFrontKnee, .leftFrontKnee), (.rightFrontKnee, .rightFrontKnee),
            (.leftFrontPaw, .leftFrontPaw), (.rightFrontPaw, .rightFrontPaw),
            (.leftBackElbow, .leftBackElbow), (.rightBackElbow, .rightBackElbow),
            (.leftBackKnee, .leftBackKnee), (.rightBackKnee, .rightBackKnee),
            (.leftBackPaw, .leftBackPaw), (.rightBackPaw, .rightBackPaw),
        ]
    }
}
