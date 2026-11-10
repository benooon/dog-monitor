import SwiftUI

/// Layout shared by the onboarding screens: content centered in the space above, actions pinned
/// to the bottom within thumb reach. Scrolls at the largest text sizes and keeps a readable
/// width on iPad.
struct OnboardingScaffold<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    /// Widest the column gets on iPad and in landscape.
    private static var readableWidth: CGFloat { 560 }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.section)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: DS.Spacing.l) {
            VStack(spacing: DS.Spacing.m) {
                actions
            }
            .padding(.bottom, DS.Spacing.l)
        }
        .padding(.horizontal, DS.Spacing.xl)
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }
}

/// App symbol, title and one line of explanation at the top of an onboarding screen.
struct OnboardingHeader: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var systemImage = "pawprint.fill"

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .padding(.bottom, DS.Spacing.s)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}

#Preview {
    OnboardingScaffold {
        OnboardingHeader(title: "Dog Monitor", message: "Sign in to watch your dog from anywhere.")
    } actions: {
        PrimaryButton(title: "Start camera") {}
    }
}

#Preview("Hebrew (RTL)") {
    OnboardingScaffold {
        OnboardingHeader(title: "Dog Monitor", message: "Sign in to watch your dog from anywhere.")
    } actions: {
        PrimaryButton(title: "Start camera") {}
    }
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    OnboardingScaffold {
        OnboardingHeader(title: "Dog Monitor", message: "Sign in to watch your dog from anywhere.")
    } actions: {
        PrimaryButton(title: "Start camera") {}
    }
    .preferredColorScheme(.dark)
}
