import DogMonitorCore
import SwiftUI

/// A dog in a list or card: its photo (or initial), name, and the profile from "Meet your dog".
struct DogRow: View {
    let dog: DogDTO
    var photo: UIImage?
    @ScaledMetric(relativeTo: .body) private var avatarSize = DogRow.avatarBaseSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Avatar side at the default text size; it grows with Dynamic Type up to twice that.
    private static let avatarBaseSize: CGFloat = 44

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Spacing.s))
            : AnyLayout(HStackLayout(spacing: DS.Spacing.m))
        layout {
            DogAvatar(name: dog.name, image: photo, size: min(avatarSize, Self.avatarBaseSize * 2))
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(verbatim: dog.name)
                    .font(.body.weight(.semibold))
                if let profile {
                    profile
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "Adult · A good balance", or whichever half is known; nil before "Meet your dog".
    private var profile: Text? {
        switch (dog.lifeStage, dog.alertStyle) {
        case let (stage?, style?): Text("\(Text(stage.title)) · \(Text(style.title))")
        case let (stage?, nil): Text(stage.title)
        case let (nil, style?): Text(style.title)
        case (nil, nil): nil
        }
    }
}

#Preview {
    let dog = HouseholdDTO.demo.dogs[0]
    List {
        DogRow(dog: dog, photo: DogPhotoStore.samplePortrait())
        DogRow(dog: DogDTO(id: UUID(), householdId: dog.householdId, name: "Luna", createdAt: .now))
    }
}

#Preview("Hebrew (RTL)") {
    let dog = HouseholdDTO.demo.dogs[0]
    List {
        DogRow(dog: dog, photo: DogPhotoStore.samplePortrait())
        DogRow(dog: DogDTO(id: UUID(), householdId: dog.householdId, name: "לונה", createdAt: .now))
    }
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    List {
        DogRow(dog: HouseholdDTO.demo.dogs[0], photo: DogPhotoStore.samplePortrait())
    }
    .preferredColorScheme(.dark)
}
