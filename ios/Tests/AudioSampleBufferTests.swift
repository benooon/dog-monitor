import AVFoundation
import XCTest
@testable import DogMonitor

final class AudioSampleBufferTests: XCTestCase {
    /// Captured audio is 16-bit interleaved PCM; it must survive the trip into an
    /// `AVAudioPCMBuffer` unchanged (format, length and samples).
    func testConvertsCapturedPCMSampleBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let frames: AVAudioFrameCount = 1024
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        source.frameLength = frames
        let samples = try XCTUnwrap(source.int16ChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = Int16(truncatingIfNeeded: index * 31)
        }

        let sampleBuffer = try Self.makeSampleBuffer(from: source)
        let converted = try XCTUnwrap(AudioSampleBuffer.pcmBuffer(from: sampleBuffer))

        XCTAssertEqual(converted.frameLength, frames)
        XCTAssertEqual(converted.format.sampleRate, 44_100)
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertEqual(converted.format.commonFormat, .pcmFormatInt16)
        let convertedSamples = try XCTUnwrap(converted.int16ChannelData?[0])
        for index in [0, 1, 500, Int(frames) - 1] {
            XCTAssertEqual(convertedSamples[index], samples[index], "sample \(index)")
        }
    }

    private static func makeSampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(createStatus, noErr)
        let result = try XCTUnwrap(sampleBuffer)
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            result,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        XCTAssertEqual(dataStatus, noErr)
        return result
    }
}
