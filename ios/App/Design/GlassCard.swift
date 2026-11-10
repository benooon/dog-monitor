import SwiftUI

/// A padded glass panel for content that floats over video or the camera preview.
/// Screens of regular content use `List` or `Form` instead.
struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(DS.Spacing.l)
            .glassSurface(in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

#Preview {
    GlassCard {
        Label("Resting", systemImage: "pawprint.fill")
    }
    .padding()
    .background(Color.accentColor.gradient)
}

#Preview("Hebrew (RTL)") {
    GlassCard {
        Label("Resting", systemImage: "pawprint.fill")
    }
    .padding()
    .background(Color.accentColor.gradient)
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    GlassCard {
        Label("Resting", systemImage: "pawprint.fill")
    }
    .padding()
    .background(Color.accentColor.gradient)
    .preferredColorScheme(.dark)
}
