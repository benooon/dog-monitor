@preconcurrency import LiveKit
import SwiftUI
import UIKit

/// Renders a LiveKit video track.
struct LiveVideoView: UIViewRepresentable {
    let track: VideoTrack

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fit
        view.track = track
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        if view.track !== track {
            view.track = track
        }
    }
}
