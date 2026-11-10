import SwiftUI
import UIKit

/// The dog's round photo with a small badge for what it's doing, or the state symbol in a
/// tinted circle when there's no photo. Used by the dog status widget and the Live Activity.
struct DogFace: View {
    let photo: UIImage?
    let symbol: String
    let tint: Color
    var size: CGFloat = 44

    var body: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.24, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .background(.thickMaterial, in: Circle())
                }
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
        }
    }
}

/// The dog's photo alone, cropped round, for tight spots like the Dynamic Island.
struct DogPhotoCircle: View {
    let photo: UIImage
    var size: CGFloat = 24

    var body: some View {
        Image(uiImage: photo)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
