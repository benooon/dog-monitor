import SwiftUI

/// One "Meet your dog" screen: a question at the top, content below it, actions pinned to the
/// bottom within thumb reach. Scrolls at large text sizes; a readable column on iPad.
struct QuestionScreen<Content: View, Actions: View>: View {
    let title: Text
    var message: Text?
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xxl) {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    title
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let message {
                        message
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                content
            }
            .padding(.top, DS.Spacing.l)
            .padding(.horizontal, DS.Spacing.xl)
            .frame(maxWidth: DS.Layout.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: DS.Spacing.l) {
            VStack(spacing: DS.Spacing.m) {
                actions
            }
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.l)
            .frame(maxWidth: DS.Layout.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A large tappable answer: symbol, title, optional subtitle, and a check when chosen.
/// Used for single choices (age, alerts) and multiple choices (habits).
struct ChoiceCard: View {
    let title: LocalizedStringKey
    var subtitle: Text?
    let systemImage: String
    let isSelected: Bool
    var badge: LocalizedStringKey?
    let action: () -> Void

    @ScaledMetric(relativeTo: .title3) private var symbolWidth: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

    init(
        title: LocalizedStringKey,
        subtitle: Text? = nil,
        systemImage: String,
        isSelected: Bool,
        badge: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.badge = badge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.l) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: symbolWidth)
                    .symbolEffect(.bounce, value: isSelected && !reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack(spacing: DS.Spacing.s) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, DS.Spacing.s)
                                .padding(.vertical, DS.Spacing.xs / 2)
                                .background(.tint.opacity(0.12), in: Capsule())
                        }
                    }
                    if let subtitle {
                        subtitle
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: DS.Spacing.s)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(isSelected ? 0.6 : 1), in: Self.shape)
            .overlay {
                Self.shape.strokeBorder(.tint, lineWidth: isSelected ? 2 : 0)
            }
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .animation(DS.Motion.animation(DS.Motion.standard, reduceMotion: reduceMotion), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A quiet text button under the primary action ("Not now", "Skip for now").
struct SecondaryActionButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
    }
}
