import Foundation

/// What to do with the dog photo the app shares with its widgets (home screen widget and the
/// Live Activity), given the household's featured dog and the version already shared.
public enum SharedDogPhotoAction: Equatable, Sendable {
    /// The shared copy is current, or the new photo hasn't loaded yet.
    case keep
    /// Write the loaded photo and remember it as `version` (a `DogPhotoVersion.fileName`).
    case write(version: String)
    /// The dog has no photo any more (or there's no dog): widgets fall back to the paw.
    case remove
}

public enum SharedDogPhotoPlan {
    /// - Parameters:
    ///   - dog: the dog the widgets show (the household's first dog), nil when it has none.
    ///   - imageLoaded: whether the phone has that dog's current photo in memory.
    ///   - shared: the version written last time, nil when nothing is shared.
    public static func action(for dog: DogDTO?, imageLoaded: Bool, shared: String?) -> SharedDogPhotoAction {
        guard let version = dog.flatMap(DogPhotoVersion.init(dog:)) else {
            return shared == nil ? .keep : .remove
        }
        guard imageLoaded, version.fileName != shared else { return .keep }
        return .write(version: version.fileName)
    }
}
