import DogMonitorCore
import UIKit
import XCTest
@testable import DogMonitor

@MainActor
final class DogPhotoStoreTests: XCTestCase {
    private let api = DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!)

    private func dog(_ id: UUID = UUID(), photoAt: Date?) -> DogDTO {
        DogDTO(id: id, householdId: UUID(), name: "Rex", photoUpdatedAt: photoAt, createdAt: .now)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStoredPhotoShowsOnlyForItsVersion() {
        let store = DogPhotoStore(directory: nil)
        let id = UUID()
        let rex = dog(id, photoAt: Date(timeIntervalSince1970: 100))
        store.store(DogPhotoStore.samplePortrait(side: 8), for: rex)
        XCTAssertNotNil(store.image(for: rex))
        XCTAssertNil(store.image(for: dog(id, photoAt: Date(timeIntervalSince1970: 200))))
        XCTAssertNil(store.image(for: dog(id, photoAt: nil)))
    }

    func testDiskCacheSurvivesANewStore() async throws {
        let directory = try temporaryDirectory()
        let rex = dog(photoAt: Date(timeIntervalSince1970: 100))
        DogPhotoStore(directory: directory).store(DogPhotoStore.samplePortrait(side: 8), for: rex)

        let relaunched = DogPhotoStore(directory: directory)
        XCTAssertNil(relaunched.image(for: rex))
        await relaunched.load([rex], api: api)
        XCTAssertNotNil(relaunched.image(for: rex))
    }

    func testRemovedPhotoClearsMemoryAndDisk() async throws {
        let directory = try temporaryDirectory()
        let id = UUID()
        let rex = dog(id, photoAt: Date(timeIntervalSince1970: 100))
        let store = DogPhotoStore(directory: directory)
        store.store(DogPhotoStore.samplePortrait(side: 8), for: rex)

        await store.load([dog(id, photoAt: nil)], api: api)
        XCTAssertNil(store.image(for: rex))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        XCTAssertEqual(files, [])
    }
}
