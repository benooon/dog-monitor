import DogMonitorCore
import UIKit

/// The household's dog photo, shared with the widget extension through the app group so the
/// dog status widget and the Live Activity show the dog's face. Small on purpose: widgets and
/// Live Activities have tight memory and image size limits.
///
/// Only shared on a device once the App Groups capability is enabled (docs/HUMAN_TODO.md);
/// until then `image()` is nil and the widgets show the dog's state symbol.
enum SharedDogPhoto {
    /// Pixels per side: sharp on a 3x avatar of 48 pt.
    static let side: CGFloat = 144
    private static let fileName = "shared-dog-photo.jpg"
    private static let versionKey = "sharedDogPhotoVersion"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DogStatusStore.appGroup)?
            .appending(path: fileName)
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: DogStatusStore.appGroup)
    }

    /// The shared photo, or nil when the dog has none (or the app group isn't set up).
    static func image() -> UIImage? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Brings the shared copy in line with `dog`'s current photo. Returns true when it changed,
    /// so the caller can reload widget timelines.
    @MainActor
    @discardableResult
    static func update(dog: DogDTO?, image: UIImage?) -> Bool {
        let shared = defaults?.string(forKey: versionKey)
        switch SharedDogPhotoPlan.action(for: dog, imageLoaded: image != nil, shared: shared) {
        case .keep:
            return false
        case .write(let version):
            guard let url = fileURL, let image,
                  let jpeg = thumbnail(of: image).jpegData(compressionQuality: 0.8),
                  (try? jpeg.write(to: url, options: .atomic)) != nil
            else { return false }
            defaults?.set(version, forKey: versionKey)
            return true
        case .remove:
            if let url = fileURL { try? FileManager.default.removeItem(at: url) }
            defaults?.removeObject(forKey: versionKey)
            return true
        }
    }

    /// The photo is already a centered square (`DogPhoto.square`); this only scales it down.
    @MainActor
    private static func thumbnail(of image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
