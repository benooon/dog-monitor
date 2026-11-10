import AVFoundation
import SwiftUI
import UIKit

/// Live preview of the capture session, backed by `AVCaptureVideoPreviewLayer`.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe: `layerClass` guarantees the layer type.
            layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
        }
    }
}
