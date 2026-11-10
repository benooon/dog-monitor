import DogMonitorCore
import SwiftUI

/// First screen: choose whether this device is a camera or a viewer.
struct RolePickerView: View {
    let onSelect: (DeviceRole) -> Void

    var body: some View {
        OnboardingScaffold {
            OnboardingHeader(title: "Dog Monitor", message: "How will this device be used?")
        } actions: {
            ForEach(DeviceRole.allCases, id: \.self) { role in
                RoleCard(role: role) { onSelect(role) }
            }
        }
    }
}

/// One choice: symbol, role name and what it means, as a single tappable card.
private struct RoleCard: View {
    let role: DeviceRole
    let action: () -> Void

    /// Keeps the two titles aligned whatever the symbol's width; grows with Dynamic Type.
    @ScaledMetric(relativeTo: .title2) private var symbolWidth: CGFloat = 36

    private static let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.l) {
                Image(systemName: role.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: symbolWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(role.title)
                        .font(.headline)
                    Text(role.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Spacing.s)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: Self.shape)
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("role-\(role.rawValue)")
    }
}

#Preview {
    RolePickerView { _ in }
}

#Preview("Hebrew (RTL)") {
    RolePickerView { _ in }
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    RolePickerView { _ in }
        .preferredColorScheme(.dark)
}
