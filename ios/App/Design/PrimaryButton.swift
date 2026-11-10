import SwiftUI

/// The one main action on a screen: full width, large, prominent glass on iOS 26
/// (bordered prominent before). Shows a spinner and ignores taps while `isLoading`.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Keeps the button's size while the spinner shows.
                label.opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .primaryButtonStyle()
        .disabled(isLoading)
        .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

private extension View {
    @ViewBuilder
    func primaryButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
        #else
        buttonStyle(.borderedProminent)
        #endif
    }
}

#Preview {
    VStack(spacing: DS.Spacing.l) {
        PrimaryButton(title: "Pair this camera", systemImage: "qrcode") {}
        PrimaryButton(title: "Pair this camera", isLoading: true) {}
    }
    .padding()
}

#Preview("Hebrew (RTL)") {
    PrimaryButton(title: "Pair this camera", systemImage: "qrcode") {}
        .padding()
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    PrimaryButton(title: "Pair this camera", systemImage: "qrcode") {}
        .padding()
        .preferredColorScheme(.dark)
}
