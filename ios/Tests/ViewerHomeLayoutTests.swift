import XCTest
@testable import DogMonitor

@MainActor
final class ViewerHomeLayoutTests: XCTestCase {
    /// One or two cameras on a portrait iPad get one large card each instead of two small ones.
    func testFewCamerasInPortraitUseOneLargeColumn() {
        XCTAssertEqual(ViewerHomeView.gridColumnCount(cameraCount: 1, width: 802, portrait: true), 1)
        XCTAssertEqual(ViewerHomeView.gridColumnCount(cameraCount: 2, width: 802, portrait: true), 1)
    }

    func testMoreCamerasInPortraitUseTwoColumns() {
        XCTAssertEqual(ViewerHomeView.gridColumnCount(cameraCount: 3, width: 802, portrait: true), 2)
        XCTAssertEqual(ViewerHomeView.gridColumnCount(cameraCount: 6, width: 990, portrait: true), 2)
    }

    /// Landscape never shows more columns than cameras, so two cameras fill the width.
    func testLandscapeColumnsAreCappedByCameraCount() {
        XCTAssertEqual(ViewerHomeView.gridColumnCount(cameraCount: 2, width: 1100, portrait: false), 2)
        XCTAssertEqual(ViewerHomeView.gridColumnCount(cameraCount: 5, width: 1100, portrait: false), 3)
        XCTAssertEqual(ViewerHomeView.gridColumnCount(cameraCount: 0, width: 1100, portrait: false), 1)
    }
}

@MainActor
final class ViewerHomeSingleColumnTests: XCTestCase {
    /// Two cameras on a portrait iPad: both cards and the dogs card fit in the screen height.
    func testTwoCardsAndDogsFitInPortraitHeight() {
        let height: CGFloat = 1_030
        let width = ViewerHomeView.singleColumnMaxWidth(height: height, cameraCount: 2)
        let snapshot = (width - 24) * 9 / 16
        let total = 2 * (snapshot + 64) + 16 + 24 + 110 + 32
        XCTAssertLessThanOrEqual(total, height + 1)
        XCTAssertGreaterThan(width, 500)
    }

    func testNeverNarrowerThanMinimumCard() {
        XCTAssertEqual(ViewerHomeView.singleColumnMaxWidth(height: 300, cameraCount: 2), 320)
    }
}
