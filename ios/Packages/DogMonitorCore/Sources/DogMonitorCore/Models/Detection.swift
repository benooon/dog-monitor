import Foundation

/// A single raw observation from an analyzer (audio or video), the input to the event engine.
public struct Detection: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        // Audio (SoundAnalysis classes + RMS meter)
        case bark
        case howl
        case whimper
        case growl
        case loudNoise
        // Video
        case motion
        case dogVisible
        case dogLying
        case dogStanding

        public var isAudio: Bool {
            switch self {
            case .bark, .howl, .whimper, .growl, .loudNoise: true
            case .motion, .dogVisible, .dogLying, .dogStanding: false
            }
        }
    }

    public var kind: Kind
    /// Classifier confidence in 0...1.
    public var confidence: Double
    public var timestamp: Date
    /// Where in the frame, for video detections.
    public var boundingBox: NormalizedRect?

    public init(kind: Kind, confidence: Double, timestamp: Date, boundingBox: NormalizedRect? = nil) {
        self.kind = kind
        self.confidence = min(max(confidence, 0), 1)
        self.timestamp = timestamp
        self.boundingBox = boundingBox
    }

    /// Default minimum confidence for audio classes (SPEC §4).
    public static let defaultAudioConfidenceThreshold = 0.7

    public func meets(threshold: Double) -> Bool {
        confidence >= threshold
    }
}
