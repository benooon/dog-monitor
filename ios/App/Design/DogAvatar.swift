import DogMonitorCore
import SwiftUI

/// The dog's face in a circle: a picked image, the stored photo, or the first letter of the
/// name on an accent wash until there is one.
struct DogAvatar: View {
    let name: String
    var image: UIImage?
    var size: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Color.accentColor.gradient.opacity(0.18))
                if let initial = name.trimmingCharacters(in: .whitespaces).first {
                    Text(String(initial).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel(image == nil ? Text("No photo yet") : Text("Photo of \(name)"))
        .accessibilityAddTraits(.isImage)
    }
}

#Preview {
    HStack(spacing: DS.Spacing.l) {
        DogAvatar(name: "Rex", size: 96)
        DogAvatar(name: "", size: 64)
    }
    .padding()
}

#Preview("Hebrew (RTL)") {
    DogAvatar(name: "רקס", size: 96)
        .padding()
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    DogAvatar(name: "Rex", size: 96)
        .padding()
        .preferredColorScheme(.dark)
}
