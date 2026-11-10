import SwiftUI

/// A small glass capsule with a colored dot and a short status ("Online", "Barking").
/// Sits over snapshots and video, so it uses glass to stay legible on any image.
struct StatusPill: View {
    let title: LocalizedStringKey
    /// The dot's color. Use system colors (`.green`, `.orange`, `.secondary`).
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xs)
        .glassSurface()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HStack {
        StatusPill(title: "Online", tint: .green)
        StatusPill(title: "Offline")
    }
    .padding()
}

#Preview("Hebrew (RTL)") {
    HStack {
        StatusPill(title: "Online", tint: .green)
        StatusPill(title: "Offline")
    }
    .padding()
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    HStack {
        StatusPill(title: "Online", tint: .green)
        StatusPill(title: "Offline")
    }
    .padding()
    .preferredColorScheme(.dark)
}
