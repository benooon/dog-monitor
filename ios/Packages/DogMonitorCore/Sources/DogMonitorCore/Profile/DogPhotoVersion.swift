import Foundation

/// One stored version of a dog's photo: the dog plus when its photo last changed. Used as the
/// cache key on the phone, so a new photo is fetched once and an unchanged one never again.
public struct DogPhotoVersion: Hashable, Sendable {
    public let dogId: UUID
    /// `DogDTO.photoUpdatedAt`, kept to the millisecond the server sends.
    public let updatedAt: Date

    public init(dogId: UUID, updatedAt: Date) {
        self.dogId = dogId
        self.updatedAt = updatedAt
    }

    /// The dog's current photo version, or nil when the dog has no photo.
    public init?(dog: DogDTO) {
        guard let updatedAt = dog.photoUpdatedAt else { return nil }
        self.init(dogId: dog.id, updatedAt: updatedAt)
    }

    private var milliseconds: Int64 {
        Int64((updatedAt.timeIntervalSince1970 * 1000).rounded())
    }

    /// File name of this version in the phone's photo cache, e.g. `<uuid>-1731272400000.jpg`.
    public var fileName: String {
        "\(dogId.uuidString.lowercased())-\(milliseconds).\(Self.fileExtension)"
    }

    static let fileExtension = "jpg"

    /// Two versions are the same photo when they agree to the millisecond, so a date that went
    /// through JSON and back still matches its cached file.
    public static func == (lhs: DogPhotoVersion, rhs: DogPhotoVersion) -> Bool {
        lhs.dogId == rhs.dogId && lhs.milliseconds == rhs.milliseconds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(dogId)
        hasher.combine(milliseconds)
    }
}

/// What the phone's dog photo cache should do for the household's current dogs.
public struct DogPhotoCachePlan: Equatable, Sendable {
    /// Photos to fetch from the server (not in memory and not on disk).
    public let toFetch: [DogPhotoVersion]
    /// Photos to read from the disk cache into memory.
    public let toRead: [DogPhotoVersion]
    /// Cached files that are no longer any dog's current photo.
    public let filesToRemove: [String]

    /// - Parameters:
    ///   - dogs: the household's dogs, in display order.
    ///   - inMemory: versions already loaded.
    ///   - cachedFiles: names of the files in the cache directory.
    public init(dogs: [DogDTO], inMemory: Set<DogPhotoVersion>, cachedFiles: [String]) {
        let current = dogs.compactMap(DogPhotoVersion.init(dog:))
        let currentFiles = Set(current.map(\.fileName))
        let files = Set(cachedFiles)
        let missing = current.filter { !inMemory.contains($0) }
        toRead = missing.filter { files.contains($0.fileName) }
        toFetch = missing.filter { !files.contains($0.fileName) }
        filesToRemove = cachedFiles
            .filter { $0.hasSuffix(".\(DogPhotoVersion.fileExtension)") && !currentFiles.contains($0) }
            .sorted()
    }
}
