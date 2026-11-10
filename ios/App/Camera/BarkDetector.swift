@preconcurrency import AVFoundation
import DogMonitorCore
import os
@preconcurrency import SoundAnalysis

/// Turns the capture session's audio into `Detection`s: dog sounds from SoundAnalysis'
/// built-in classifier (1 s windows, 50% overlap) plus generic loud noise from an RMS meter.
///
/// Call `run(samples:)` from a task; it returns when the stream ends or the task is cancelled.
/// Detections are published through `detections(...)`.
final class BarkDetector: @unchecked Sendable {
    private let confidenceThreshold: Double
    private let broadcaster = Broadcaster<Detection>()
    private let logger = Logger(subsystem: "com.benooon.dogmonitor", category: "BarkDetector")

    // State below is only touched from `run`, which processes samples one at a time.
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: ResultsObserver?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var analysisFormat: AVAudioFormat?
    private var loudness: LoudnessDetector?
    private var framePosition: AVAudioFramePosition = 0

    init(confidenceThreshold: Double = Detection.defaultAudioConfidenceThreshold) {
        self.confidenceThreshold = confidenceThreshold
    }

    func detections(bufferingNewest limit: Int = 16) -> AsyncStream<Detection> {
        broadcaster.subscribe(bufferingNewest: limit)
    }

    func run(samples: AsyncStream<CaptureSample>) async {
        for await sample in samples where sample.kind == .audio {
            if Task.isCancelled { break }
            process(sample.buffer)
        }
        analyzer?.completeAnalysis()
        reset()
    }

    // MARK: - Private

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if format != inputFormat {
            configure(for: format)
        }
        guard let converter, let analysisFormat, let analyzer,
              let input = AudioSampleBuffer.pcmBuffer(from: sampleBuffer, format: format),
              let output = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: input.frameLength)
        else { return }

        do {
            try converter.convert(to: output, from: input)
        } catch {
            logger.error("Audio conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard output.frameLength > 0 else { return }

        analyzer.analyze(output, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(output.frameLength)

        if let channel = output.floatChannelData?[0] {
            let samples = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            for detection in loudness?.process(samples, at: Date()) ?? [] {
                broadcaster.yield(detection)
            }
        }
    }

    /// (Re)creates the analyzer for a new input format, e.g. on first audio or a route change.
    private func configure(for format: AVAudioFormat) {
        analyzer?.completeAnalysis()
        reset()
        inputFormat = format

        // SoundAnalysis and the RMS meter both get mono Float32 at the input sample rate.
        guard let target = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: format, to: target)
        else {
            logger.error("Unsupported audio format: \(format.description, privacy: .public)")
            return
        }
        let analyzer = SNAudioStreamAnalyzer(format: target)
        let observer = ResultsObserver(threshold: confidenceThreshold, broadcaster: broadcaster, logger: logger)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.overlapFactor = 0.5
            let missing = SoundClassMapping.unknownIdentifiers(knownByClassifier: request.knownClassifications)
            if !missing.isEmpty {
                logger.warning("Classifier lacks labels: \(missing.joined(separator: ", "), privacy: .public)")
            }
            try analyzer.add(request, withObserver: observer)
        } catch {
            logger.error("Could not start sound classification: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.converter = converter
        self.analysisFormat = target
        self.analyzer = analyzer
        self.observer = observer
        self.loudness = LoudnessDetector(sampleRate: format.sampleRate)
    }

    private func reset() {
        analyzer = nil
        observer = nil
        converter = nil
        inputFormat = nil
        analysisFormat = nil
        loudness = nil
        framePosition = 0
    }
}

/// Receives SoundAnalysis results (on SoundAnalysis' own queue) and publishes detections.
private final class ResultsObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let threshold: Double
    private let broadcaster: Broadcaster<Detection>
    private let logger: Logger

    init(threshold: Double, broadcaster: Broadcaster<Detection>, logger: Logger) {
        self.threshold = threshold
        self.broadcaster = broadcaster
        self.logger = logger
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let classifications = result.classifications.map {
            SoundClassification(identifier: $0.identifier, confidence: $0.confidence)
        }
        for detection in SoundClassMapping.detections(from: classifications, at: Date(), threshold: threshold) {
            broadcaster.yield(detection)
        }
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        logger.error("Sound classification failed: \(error.localizedDescription, privacy: .public)")
    }
}
