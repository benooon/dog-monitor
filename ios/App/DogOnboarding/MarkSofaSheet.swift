import SwiftUI

/// How to draw the sofa as a no-go zone on the camera phone, so sofa alerts can start.
/// Zones are drawn on what the camera sees, so this only explains the steps there.
struct MarkSofaSheet: View {
    let dogName: String

    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var stepBadgeSize: CGFloat = 32

    /// Smallest tappable size (HIG).
    static let minimumTapTarget: CGFloat = 44

    private var steps: [Text] {
        [
            Text("On the camera phone at home, tap Zones."),
            Text("Choose Sofa, then tap its corners."),
            Text("Tap Add zone, then Save."),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xxl) {
                    Image(systemName: "sofa.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("We'll tell you when \(dogName) gets on the sofa once it's marked on the camera.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: DS.Spacing.l) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
                                Text(index + 1, format: .number)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(width: stepBadgeSize, height: stepBadgeSize)
                                    .background(.tint, in: Circle())
                                    .accessibilityHidden(true)
                                step
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .padding(DS.Spacing.xl)
                .frame(maxWidth: DS.Layout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Mark the sofa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        MarkSofaSheet(dogName: "Rex")
    }
}

#Preview("Hebrew (RTL)") {
    Color.clear.sheet(isPresented: .constant(true)) {
        MarkSofaSheet(dogName: "רקס")
            .environment(\.locale, Locale(identifier: "he"))
            .environment(\.layoutDirection, .rightToLeft)
    }
}

#Preview("Dark") {
    Color.clear.sheet(isPresented: .constant(true)) {
        MarkSofaSheet(dogName: "Rex")
    }
    .preferredColorScheme(.dark)
}
