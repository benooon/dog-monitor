@preconcurrency import AVFoundation
import DogMonitorCore
import SwiftUI
import UIKit

/// Live camera view that reports the first scanned QR code holding a pairing token or code.
/// Callers must have camera permission before showing it.
struct QRScannerView: UIViewRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.session
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "com.benooon.dogmonitor.qr")
        private let onCode: @MainActor (String) -> Void
        // Main thread only (the metadata delegate queue is .main).
        private var lastDelivered: String?

        init(onCode: @escaping @MainActor (String) -> Void) {
            self.onCode = onCode
        }

        func start() {
            queue.async { [self] in
                session.beginConfiguration()
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input)
                else {
                    session.commitConfiguration()
                    return
                }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    return
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration()
                session.startRunning()
            }
        }

        func stop() {
            queue.async { [self] in
                session.stopRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let value = metadataObjects
                .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
                .first { PairingCode.parse($0) != nil }
            guard let value else { return }
            MainActor.assumeIsolated {
                // The same code is reported many times per second; deliver it once.
                guard value != lastDelivered else { return }
                lastDelivered = value
                onCode(value)
            }
        }
    }
}
