@preconcurrency import AVFoundation
import DogMonitorCore

/// Turns camera frames into small luma frames for `MotionDetector` (SPEC §4 layer 1).
enum MotionAnalyzer {
    /// Width of the analyzed frame; 64 px is plenty to see a dog move and costs almost nothing.
    static let analysisWidth = 64

    /// Reads the luma (Y) plane of a bi-planar camera buffer and downsamples it.
    static func lumaFrame(from sample: CaptureSample, timestamp: Date) -> LumaFrame? {
        guard sample.kind == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sample.buffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let plane = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height)
        return LumaFrame.downsample(
            plane,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            targetWidth: analysisWidth,
            timestamp: timestamp
        )
    }
}
