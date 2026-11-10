import Foundation
import XCTest
@testable import DogMonitorCore

final class SoundClassMappingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testMapsDogClassesAboveThreshold() {
        let detections = SoundClassMapping.detections(
            from: [
                SoundClassification(identifier: "dog_bark", confidence: 0.92),
                SoundClassification(identifier: "dog_whimper", confidence: 0.75),
                SoundClassification(identifier: "speech", confidence: 0.99),
                SoundClassification(identifier: "dog_growl", confidence: 0.4),
            ],
            at: now
        )
        XCTAssertEqual(detections.map(\.kind), [.bark, .whimper])
        XCTAssertEqual(detections.first?.confidence, 0.92)
        XCTAssertTrue(detections.allSatisfy { $0.timestamp == now && $0.kind.isAudio })
    }

    func testKeepsBestLabelPerKind() {
        let detections = SoundClassMapping.detections(
            from: [
                SoundClassification(identifier: "dog_bark", confidence: 0.71),
                SoundClassification(identifier: "dog_bow_wow", confidence: 0.88),
            ],
            at: now
        )
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.kind, .bark)
        XCTAssertEqual(detections.first?.confidence, 0.88)
    }

    func testThresholdIsInclusiveAndConfigurable() {
        let input = [SoundClassification(identifier: "dog_howl", confidence: 0.7)]
        XCTAssertEqual(SoundClassMapping.detections(from: input, at: now).map(\.kind), [.howl])
        XCTAssertTrue(SoundClassMapping.detections(from: input, at: now, threshold: 0.8).isEmpty)
    }

    func testUnknownIdentifiers() {
        let missing = SoundClassMapping.unknownIdentifiers(knownByClassifier: ["dog_bark", "dog_howl", "speech"])
        XCTAssertEqual(missing, ["dog_bow_wow", "dog_growl", "dog_whimper"])
    }

    func testCustomModelLabels() {
        let now = Date(timeIntervalSince1970: 1_000)
        let input = [
            SoundClassification(identifier: "bark", confidence: 0.9),
            SoundClassification(identifier: "other", confidence: 0.95),
        ]
        XCTAssertEqual(SoundClassMapping.detections(from: input, at: now).map(\.kind), [.bark])
    }
}

final class LoudnessDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testDecibels() {
        XCTAssertEqual(AudioLevel.decibels(rms: 1), 0, accuracy: 0.001)
        XCTAssertEqual(AudioLevel.decibels(rms: 0.1), -20, accuracy: 0.001)
        XCTAssertEqual(AudioLevel.decibels(rms: 0), AudioLevel.silenceDecibels)
    }

    func testRMS() {
        XCTAssertEqual(AudioLevel.rms([Float]()), 0)
        XCTAssertEqual(AudioLevel.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 0.0001)
    }

    func testQuietAudioProducesNothing() {
        var detector = LoudnessDetector(sampleRate: 100, windowDuration: 0.5)
        let quiet = [Float](repeating: 0.01, count: 200) // -40 dBFS
        XCTAssertTrue(detector.process(quiet, at: now).isEmpty)
        XCTAssertEqual(detector.lastLevelDecibels, -40, accuracy: 0.01)
    }

    func testLoudWindowsAreReported() {
        var detector = LoudnessDetector(sampleRate: 100, windowDuration: 0.5, thresholdDecibels: -20)
        let loud = [Float](repeating: 0.5, count: 100) // -6 dBFS, two windows of 50 samples
        let detections = detector.process(loud, at: now)
        XCTAssertEqual(detections.map(\.kind), [.loudNoise, .loudNoise])
    }

    func testWindowsSpanMultipleBuffers() {
        var detector = LoudnessDetector(sampleRate: 100, windowDuration: 0.5)
        let loud = [Float](repeating: 0.5, count: 30)
        XCTAssertTrue(detector.process(loud, at: now).isEmpty)
        XCTAssertEqual(detector.process(loud, at: now).count, 1) // 60 samples: one full window
    }
}

final class DetectionLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testKeepsNewestUpToCapacity() {
        var log = DetectionLog(capacity: 3)
        for i in 0..<5 {
            log.append(Detection(kind: .bark, confidence: 0.8, timestamp: t0 + Double(i)))
        }
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.latest(2).map(\.timestamp), [t0 + 4, t0 + 3])
    }

    func testCountsKindWithinWindow() {
        var log = DetectionLog()
        log.append(Detection(kind: .bark, confidence: 0.8, timestamp: t0))
        log.append(Detection(kind: .bark, confidence: 0.8, timestamp: t0 + 30))
        log.append(Detection(kind: .whimper, confidence: 0.8, timestamp: t0 + 40))
        log.append(Detection(kind: .bark, confidence: 0.8, timestamp: t0 + 50))
        XCTAssertEqual(log.count(of: .bark, within: 60, before: t0 + 60), 2)
        XCTAssertEqual(log.count(of: .bark, within: 60, before: t0 + 59), 3)
        XCTAssertEqual(log.count(of: .whimper, within: 60, before: t0 + 60), 1)
    }
}
