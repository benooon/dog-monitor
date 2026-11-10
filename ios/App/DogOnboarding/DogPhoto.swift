import UIKit

/// The dog's photo as it is stored: a centered square, small enough for the server's 512 KB limit.
@MainActor
enum DogPhoto {
    /// Pixels per side of the uploaded photo (sharp on a 3x avatar of about 170 pt).
    static let uploadSide: CGFloat = 512
    private static let jpegQuality: CGFloat = 0.8

    /// The largest centered square of `image`, scaled to `side` pixels, with orientation applied.
    static func square(_ image: UIImage, side: CGFloat) -> UIImage {
        let size = image.size
        let edge = min(size.width, size.height)
        guard edge > 0 else { return image }
        let scale = side / edge
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }

    static func jpeg(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: jpegQuality)
    }
}
