@preconcurrency import CoreML
import Foundation

/// The slot for a custom sound classifier trained with Create ML (docs/TRAINING.md). When a model
/// is installed, bark detection uses it instead of SoundAnalysis' built-in classifier.
enum CustomSoundModel {
    enum InstallError: Error {
        case notASoundClassifier
    }

    static var compiledURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CustomSoundModel.mlmodelc", isDirectory: true)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: compiledURL.path)
    }

    /// The installed model, or nil to use the built-in classifier.
    static func load() -> MLModel? {
        guard isInstalled else { return nil }
        return try? MLModel(contentsOf: compiledURL)
    }

    /// Compiles a `.mlmodel` / `.mlpackage` picked by the user and installs it.
    static func install(from source: URL) async throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let compiled = try await MLModel.compileModel(at: source)
        // A sound classifier takes audio samples in and gives class labels out.
        let model = try MLModel(contentsOf: compiled)
        guard model.modelDescription.classLabels != nil else { throw InstallError.notASoundClassifier }
        let destination = compiledURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: compiled, to: destination)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: compiledURL)
    }
}
