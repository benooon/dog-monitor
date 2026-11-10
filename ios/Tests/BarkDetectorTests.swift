import DogMonitorCore
import SoundAnalysis
import XCTest
@testable import DogMonitor

final class BarkDetectorTests: XCTestCase {
    /// Guards the label names in `SoundClassMapping` against the real built-in classifier.
    func testBuiltInClassifierKnowsOurDogLabels() throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        XCTAssertEqual(
            SoundClassMapping.unknownIdentifiers(knownByClassifier: request.knownClassifications),
            []
        )
    }

    func testRunReturnsWhenSamplesEnd() async {
        let detector = BarkDetector()
        let (samples, continuation) = AsyncStream<CaptureSample>.makeStream()
        continuation.finish()
        await detector.run(samples: samples)
    }
}
