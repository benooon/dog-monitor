import SwiftUI

/// Liquid Glass on iOS 26 and later, a system material before that. For floating chrome only
/// (controls over the camera or live video, primary actions), never for regular content.
struct GlassSurface<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    var isInteractive = false

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(isInteractive), in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content.background(.regularMaterial, in: shape)
    }
}

extension View {
    /// A capsule of glass behind the view.
    func glassSurface(isInteractive: Bool = false) -> some View {
        modifier(GlassSurface(shape: Capsule(), isInteractive: isInteractive))
    }

    /// Glass in the given shape behind the view.
    func glassSurface<SurfaceShape: Shape>(in shape: SurfaceShape, isInteractive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, isInteractive: isInteractive))
    }
}
