import DogMonitorCore
import Foundation
import Observation
import UIKit

/// The household's dog photos for the whole app: kept in memory, cached on disk by dog and
/// photo version (`DogPhotoVersion`), and fetched from `GET /dogs/:id/photo` only when new.
@MainActor
@Observable
final class DogPhotoStore {
    private var images: [DogPhotoVersion: UIImage] = [:]
    /// Nil keeps photos in memory only (previews, screenshots, tests).
    private let directory: URL?

    init(directory: URL? = DogPhotoStore.defaultDirectory) {
        self.directory = directory
    }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "DogPhotos", directoryHint: .isDirectory)
    }

    /// The dog's current photo, or nil when it has none (or it hasn't loaded yet).
    func image(for dog: DogDTO) -> UIImage? {
        DogPhotoVersion(dog: dog).flatMap { images[$0] }
    }

    /// Keeps a photo the phone already has (just picked in "Meet your dog"), so it shows
    /// right away instead of being downloaded again.
    func store(_ image: UIImage, for dog: DogDTO) {
        guard let version = DogPhotoVersion(dog: dog) else { return }
        images[version] = image
        if let url = fileURL(version), let jpeg = DogPhoto.jpeg(image) {
            try? createDirectory()
            try? jpeg.write(to: url, options: .atomic)
        }
    }

    /// Loads the current photo of each dog. Best effort: a photo that fails to load keeps the
    /// avatar's initial and is tried again on the next household refresh.
    func load(_ dogs: [DogDTO], api: DogMonitorAPI) async {
        let plan = DogPhotoCachePlan(dogs: dogs, inMemory: Set(images.keys), cachedFiles: cachedFiles())
        for version in plan.toRead {
            if let url = fileURL(version), let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                images[version] = image
            }
        }
        for version in plan.toFetch {
            guard let data = try? await api.dogPhoto(id: version.dogId), let image = UIImage(data: data) else { continue }
            images[version] = image
            if let url = fileURL(version) {
                try? createDirectory()
                try? data.write(to: url, options: .atomic)
            }
        }
        let current = Set(dogs.compactMap(DogPhotoVersion.init(dog:)))
        images = images.filter { current.contains($0.key) }
        for name in plan.filesToRemove {
            if let directory {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }

    private func fileURL(_ version: DogPhotoVersion) -> URL? {
        directory?.appending(path: version.fileName)
    }

    private func cachedFiles() -> [String] {
        guard let directory else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    private func createDirectory() throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

extension DogPhotoStore {
    /// A soft illustrated portrait for previews and CI screenshots (no real photo ships with the app).
    static func samplePortrait(side: CGFloat = DogPhoto.uploadSide) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let accent = UIColor(named: "AccentColor") ?? .systemOrange
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let colors = [accent.withAlphaComponent(0.55).cgColor, accent.cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: side), options: [])
            }
            let symbol = UIImage(
                systemName: "dog.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.5, weight: .regular)
            )?.withTintColor(UIColor(white: 1, alpha: 0.92), renderingMode: .alwaysOriginal)
            if let symbol {
                let origin = CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2 + side * 0.04)
                symbol.draw(in: CGRect(origin: origin, size: symbol.size))
            }
        }
    }
}
