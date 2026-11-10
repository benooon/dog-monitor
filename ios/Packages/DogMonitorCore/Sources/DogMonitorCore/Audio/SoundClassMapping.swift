import Foundation

/// One label from a sound classifier (e.g. SoundAnalysis' built-in classifier) for one window.
public struct SoundClassification: Sendable, Hashable {
    public var identifier: String
    public var confidence: Double

    public init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

/// Maps SoundAnalysis built-in classifier labels to our audio `Detection` kinds (SPEC §4).
public enum SoundClassMapping {
    /// Built-in classifier (`SNClassifierIdentifier.version1`) labels we care about.
    public static let kindsByIdentifier: [String: Detection.Kind] = [
        "dog_bark": .bark,
        "dog_bow_wow": .bark,
        "dog_howl": .howl,
        "dog_whimper": .whimper,
        "dog_growl": .growl,
    ]

    /// Detections for one classification window: at most one per kind (its best label),
    /// only those at or above `threshold`, highest confidence first.
    public static func detections(
        from classifications: [SoundClassification],
        at timestamp: Date,
        threshold: Double = Detection.defaultAudioConfidenceThreshold
    ) -> [Detection] {
        var best: [Detection.Kind: Double] = [:]
        for classification in classifications {
            guard let kind = kindsByIdentifier[classification.identifier],
                  classification.confidence >= threshold
            else { continue }
            best[kind] = max(best[kind] ?? 0, classification.confidence)
        }
        return best
            .map { Detection(kind: $0.key, confidence: $0.value, timestamp: timestamp) }
            .sorted { lhs, rhs in
                lhs.confidence != rhs.confidence
                    ? lhs.confidence > rhs.confidence
                    : lhs.kind.rawValue < rhs.kind.rawValue
            }
    }

    /// Labels we map that the classifier does not know (useful to log after an OS update).
    public static func unknownIdentifiers(knownByClassifier known: [String]) -> [String] {
        let known = Set(known)
        return kindsByIdentifier.keys.filter { !known.contains($0) }.sorted()
    }
}
