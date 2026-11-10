import Foundation

/// Generic loud-noise detection from an RMS level meter (SPEC §4).
///
/// Feed it raw PCM samples (Float, -1...1) as they arrive. It aggregates them into windows
/// of `windowDuration` and reports a `.loudNoise` detection for each window whose RMS level
/// is at or above `thresholdDecibels` (dBFS).
public struct LoudnessDetector: Sendable {
    public static let defaultThresholdDecibels: Float = -20

    public let sampleRate: Double
    public let windowDuration: Double
    public let thresholdDecibels: Float
    /// RMS level of the last completed window, in dBFS (for a level meter UI).
    public private(set) var lastLevelDecibels: Float = AudioLevel.silenceDecibels

    private var sumOfSquares: Double = 0
    private var sampleCount = 0

    public init(sampleRate: Double, windowDuration: Double = 0.5, thresholdDecibels: Float = Self.defaultThresholdDecibels) {
        self.sampleRate = max(sampleRate, 1)
        self.windowDuration = max(windowDuration, 0.01)
        self.thresholdDecibels = thresholdDecibels
    }

    private var samplesPerWindow: Int {
        max(Int(sampleRate * windowDuration), 1)
    }

    /// Adds samples; returns a detection for every window completed by them that was loud.
    public mutating func process<C: Collection>(_ samples: C, at timestamp: Date) -> [Detection] where C.Element == Float {
        var detections: [Detection] = []
        for sample in samples {
            sumOfSquares += Double(sample) * Double(sample)
            sampleCount += 1
            if sampleCount >= samplesPerWindow {
                let level = AudioLevel.decibels(rms: Float((sumOfSquares / Double(sampleCount)).squareRoot()))
                lastLevelDecibels = level
                sumOfSquares = 0
                sampleCount = 0
                if level >= thresholdDecibels {
                    detections.append(Detection(kind: .loudNoise, confidence: 1, timestamp: timestamp))
                }
            }
        }
        return detections
    }
}

public enum AudioLevel {
    /// Floor used for digital silence instead of -infinity.
    public static let silenceDecibels: Float = -160

    public static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// dBFS of an RMS amplitude, where 1.0 is full scale (0 dB).
    public static func decibels(rms: Float) -> Float {
        guard rms > 0 else { return silenceDecibels }
        return max(20 * log10(rms), silenceDecibels)
    }
}
