@preconcurrency import AVFoundation

/// Conversion of captured audio `CMSampleBuffer`s into `AVAudioPCMBuffer`s, shared by
/// bark detection and live audio publishing.
enum AudioSampleBuffer {
    /// Copies the PCM data of an audio sample buffer into a new `AVAudioPCMBuffer`.
    /// Returns nil for non-audio or empty buffers.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        return pcmBuffer(from: sampleBuffer, format: AVAudioFormat(cmAudioFormatDescription: description))
    }

    /// Same as `pcmBuffer(from:)` with a format the caller already derived from the buffer.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
