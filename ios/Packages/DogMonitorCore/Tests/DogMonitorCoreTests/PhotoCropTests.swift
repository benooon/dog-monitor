import XCTest
@testable import DogMonitorCore

final class PhotoCropTests: XCTestCase {
    private func assertRect(
        _ rect: (x: Double, y: Double, side: Double),
        _ x: Double, _ y: Double, _ side: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(rect.x, x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.y, y, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.side, side, accuracy: 0.001, file: file, line: line)
    }

    func testStartsWithTheCenteredSquare() {
        let crop = PhotoCrop(imageWidth: 1200, imageHeight: 800, viewport: 300)
        XCTAssertEqual(crop.displayHeight, 300, accuracy: 0.001)
        XCTAssertEqual(crop.displayWidth, 450, accuracy: 0.001)
        assertRect(crop.cropRect, 200, 0, 800)
    }

    func testMovingRightShowsMoreOfTheLeftSide() {
        var crop = PhotoCrop(imageWidth: 1200, imageHeight: 800, viewport: 300)
        crop.set(zoom: 1, offsetX: 75, offsetY: 0)
        assertRect(crop.cropRect, 0, 0, 800)
    }

    func testThePhotoAlwaysCoversTheViewport() {
        var crop = PhotoCrop(imageWidth: 1200, imageHeight: 800, viewport: 300)
        crop.set(zoom: 1, offsetX: 500, offsetY: 40)
        XCTAssertEqual(crop.offsetX, 75, accuracy: 0.001)
        XCTAssertEqual(crop.offsetY, 0, accuracy: 0.001, "no room to move vertically at zoom 1")
        assertRect(crop.cropRect, 0, 0, 800)
    }

    func testZoomIsLimitedAndNarrowsTheCrop() {
        var crop = PhotoCrop(imageWidth: 1000, imageHeight: 1000, viewport: 250)
        crop.set(zoom: 0.5, offsetX: 0, offsetY: 0)
        XCTAssertEqual(crop.zoom, 1)
        crop.set(zoom: 9, offsetX: 0, offsetY: 0)
        XCTAssertEqual(crop.zoom, PhotoCrop.maxZoom)

        crop.set(zoom: 2, offsetX: -125, offsetY: 125)
        // Zoom 2 shows a 500 px square. Moving the photo left and down shows its top-right quarter.
        assertRect(crop.cropRect, 500, 0, 500)
    }
}
