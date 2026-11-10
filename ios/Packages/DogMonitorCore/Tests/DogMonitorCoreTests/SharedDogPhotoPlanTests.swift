import Foundation
import XCTest
@testable import DogMonitorCore

final class SharedDogPhotoPlanTests: XCTestCase {
    private func dog(photoAt: Date?) -> DogDTO {
        DogDTO(id: UUID(), householdId: UUID(), name: "Rex", photoUpdatedAt: photoAt, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testWritesALoadedPhotoThatIsNotSharedYet() throws {
        let rex = dog(photoAt: Date(timeIntervalSince1970: 100))
        let name = try XCTUnwrap(DogPhotoVersion(dog: rex)).fileName
        XCTAssertEqual(SharedDogPhotoPlan.action(for: rex, imageLoaded: true, shared: nil), .write(version: name))
    }

    func testKeepsTheSharedPhotoWhenItIsCurrent() throws {
        let rex = dog(photoAt: Date(timeIntervalSince1970: 100))
        let name = try XCTUnwrap(DogPhotoVersion(dog: rex)).fileName
        XCTAssertEqual(SharedDogPhotoPlan.action(for: rex, imageLoaded: true, shared: name), .keep)
    }

    func testReplacesAnOlderVersion() throws {
        let rex = dog(photoAt: Date(timeIntervalSince1970: 200))
        let name = try XCTUnwrap(DogPhotoVersion(dog: rex)).fileName
        XCTAssertEqual(SharedDogPhotoPlan.action(for: rex, imageLoaded: true, shared: "old.jpg"), .write(version: name))
    }

    func testWaitsForANewPhotoToLoad() {
        let rex = dog(photoAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(SharedDogPhotoPlan.action(for: rex, imageLoaded: false, shared: "old.jpg"), .keep)
        XCTAssertEqual(SharedDogPhotoPlan.action(for: rex, imageLoaded: false, shared: nil), .keep)
    }

    func testRemovesWhenThePhotoOrDogIsGone() {
        XCTAssertEqual(SharedDogPhotoPlan.action(for: dog(photoAt: nil), imageLoaded: false, shared: "old.jpg"), .remove)
        XCTAssertEqual(SharedDogPhotoPlan.action(for: nil, imageLoaded: false, shared: "old.jpg"), .remove)
    }

    func testNothingToDoWithoutAPhoto() {
        XCTAssertEqual(SharedDogPhotoPlan.action(for: dog(photoAt: nil), imageLoaded: false, shared: nil), .keep)
        XCTAssertEqual(SharedDogPhotoPlan.action(for: nil, imageLoaded: false, shared: nil), .keep)
    }
}
