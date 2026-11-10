import Foundation
import XCTest
@testable import DogMonitorCore

final class DogPhotoCacheTests: XCTestCase {
    private let household = UUID()

    private func dog(_ id: UUID = UUID(), photoAt: Date?) -> DogDTO {
        DogDTO(id: id, householdId: household, name: "Rex", photoUpdatedAt: photoAt, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testNoPhotoHasNoVersion() {
        XCTAssertNil(DogPhotoVersion(dog: dog(photoAt: nil)))
    }

    func testFileNameUsesLowercasedIdAndMilliseconds() throws {
        let id = try XCTUnwrap(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let version = try XCTUnwrap(DogPhotoVersion(dog: dog(id, photoAt: Date(timeIntervalSince1970: 1_731_272_400.123))))
        XCTAssertEqual(version.fileName, "6f9619ff-8b86-d011-b42d-00c04fc964ff-1731272400123.jpg")
    }

    func testVersionsMatchToTheMillisecond() {
        let id = UUID()
        let a = DogPhotoVersion(dogId: id, updatedAt: Date(timeIntervalSince1970: 100.1234))
        let b = DogPhotoVersion(dogId: id, updatedAt: Date(timeIntervalSince1970: 100.1231))
        let c = DogPhotoVersion(dogId: id, updatedAt: Date(timeIntervalSince1970: 100.2))
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertNotEqual(a, c)
    }

    func testFetchesNewPhotosAndReadsCachedOnes() throws {
        let cached = dog(photoAt: Date(timeIntervalSince1970: 10))
        let fresh = dog(photoAt: Date(timeIntervalSince1970: 20))
        let noPhoto = dog(photoAt: nil)
        let cachedVersion = try XCTUnwrap(DogPhotoVersion(dog: cached))
        let plan = DogPhotoCachePlan(dogs: [cached, fresh, noPhoto], inMemory: [], cachedFiles: [cachedVersion.fileName])
        XCTAssertEqual(plan.toRead, [cachedVersion])
        XCTAssertEqual(plan.toFetch, [DogPhotoVersion(dog: fresh)].compactMap { $0 })
        XCTAssertEqual(plan.filesToRemove, [])
    }

    func testLoadedPhotosNeedNothing() throws {
        let rex = dog(photoAt: Date(timeIntervalSince1970: 10))
        let version = try XCTUnwrap(DogPhotoVersion(dog: rex))
        let plan = DogPhotoCachePlan(dogs: [rex], inMemory: [version], cachedFiles: [version.fileName])
        XCTAssertEqual(plan, DogPhotoCachePlan(dogs: [], inMemory: [], cachedFiles: []))
    }

    func testChangedPhotoReplacesTheOldFile() throws {
        let id = UUID()
        let old = try XCTUnwrap(DogPhotoVersion(dog: dog(id, photoAt: Date(timeIntervalSince1970: 10))))
        let rex = dog(id, photoAt: Date(timeIntervalSince1970: 99))
        let plan = DogPhotoCachePlan(dogs: [rex], inMemory: [old], cachedFiles: [old.fileName, ".DS_Store"])
        XCTAssertEqual(plan.toFetch.map(\.dogId), [id])
        XCTAssertEqual(plan.filesToRemove, [old.fileName])
    }

    func testRemovedPhotoAndRemovedDogClearTheirFiles() throws {
        let id = UUID()
        let old = try XCTUnwrap(DogPhotoVersion(dog: dog(id, photoAt: Date(timeIntervalSince1970: 10))))
        let gone = try XCTUnwrap(DogPhotoVersion(dog: dog(photoAt: Date(timeIntervalSince1970: 5))))
        let plan = DogPhotoCachePlan(dogs: [dog(id, photoAt: nil)], inMemory: [], cachedFiles: [old.fileName, gone.fileName])
        XCTAssertEqual(plan.toFetch, [])
        XCTAssertEqual(plan.toRead, [])
        XCTAssertEqual(Set(plan.filesToRemove), [old.fileName, gone.fileName])
    }
}
