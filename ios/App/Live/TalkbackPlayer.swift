@preconcurrency import AVFoundation
@preconcurrency import LiveKit

/// Plays viewers' push-to-talk audio out of the camera phone's speaker.
///
/// LiveKit runs in manual rendering mode on the camera (the capture session owns the mic), so
/// remote audio is not played for us. Instead each viewer's audio track renders into this object,
/// which converts the buffers to the standard float format and plays them on its own engine.
/// `render` is called on WebRTC's audio thread, so it only converts and hands off.
final class TalkbackPlayer: NSObject, AudioRenderer, @unchecked Sendable {
    /// Audio this recent counts as "a viewer is talking".
    static let talkingWindow: TimeInterval = 1.5

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.benooon.dogmonitor.talkback")
    // Guarded by `lock`.
    private var converter: AVAudioConverter?
    private var lastAudioAt: Date?
    // Touched only on `queue`.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?

    var isViewerTalking: Bool {
        lock.withLock {
            guard let lastAudioAt else { return false }
            return Date.now.timeIntervalSince(lastAudioAt) < Self.talkingWindow
        }
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard pcmBuffer.frameLength > 0, let converted = convert(pcmBuffer) else { return }
        let box = BufferBox(buffer: converted)
        queue.async { [self] in schedule(box.buffer) }
    }

    func stop() {
        lock.withLock {
            converter = nil
            lastAudioAt = nil
        }
        queue.async { [self] in
            player?.stop()
            engine?.stop()
            engine = nil
            player = nil
            playerFormat = nil
        }
    }

    // MARK: - Private

    /// A copy of `input` in the standard (deinterleaved float) format at the same rate.
    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.withLock {
            guard let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: input.format.sampleRate,
                channels: input.format.channelCount
            ) else { return nil }
            if converter == nil || converter?.inputFormat != input.format || converter?.outputFormat != outputFormat {
                converter = AVAudioConverter(from: input.format, to: outputFormat)
            }
            guard let converter,
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: input.frameLength)
            else { return nil }
            do {
                try converter.convert(to: output, from: input)
            } catch {
                return nil
            }
            lastAudioAt = .now
            return output
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        if playerFormat != buffer.format {
            startEngine(format: buffer.format)
        }
        guard let player, engine?.isRunning == true else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func startEngine(format: AVAudioFormat) {
        player?.stop()
        engine?.stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            self.engine = nil
            self.player = nil
            playerFormat = nil
            return
        }
        self.engine = engine
        self.player = player
        playerFormat = format
    }
}

/// A converted buffer handed from the audio thread to the playback queue; nothing else holds it.
private struct BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
