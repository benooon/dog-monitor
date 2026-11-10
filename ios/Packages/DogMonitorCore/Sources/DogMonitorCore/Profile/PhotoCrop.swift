import Foundation

/// Moving and zooming a photo inside a square viewport (the round avatar crop). At zoom 1 the
/// photo fills the viewport (aspect fill, centered); the offset moves it in viewport points.
/// The photo always covers the viewport, so the crop never shows empty space. Pure geometry,
/// so the gestures only feed it and the renderer only reads `cropRect`.
public struct PhotoCrop: Equatable, Sendable {
    public static let maxZoom = 4.0

    public let imageWidth: Double
    public let imageHeight: Double
    /// Side of the square viewport, in points.
    public let viewport: Double
    public private(set) var zoom: Double = 1
    public private(set) var offsetX: Double = 0
    public private(set) var offsetY: Double = 0

    public init(imageWidth: Double, imageHeight: Double, viewport: Double) {
        self.imageWidth = max(imageWidth, 1)
        self.imageHeight = max(imageHeight, 1)
        self.viewport = max(viewport, 1)
    }

    /// Points on screen per image pixel at the current zoom.
    public var displayScale: Double {
        viewport / min(imageWidth, imageHeight) * zoom
    }

    /// Size of the photo on screen at the current zoom.
    public var displayWidth: Double { imageWidth * displayScale }
    public var displayHeight: Double { imageHeight * displayScale }

    /// Sets zoom and offset, keeping the photo covering the viewport.
    public mutating func set(zoom: Double, offsetX: Double, offsetY: Double) {
        self.zoom = min(max(zoom, 1), Self.maxZoom)
        let maxX = (displayWidth - viewport) / 2
        let maxY = (displayHeight - viewport) / 2
        self.offsetX = min(max(offsetX, -maxX), maxX)
        self.offsetY = min(max(offsetY, -maxY), maxY)
    }

    /// The square of the original image that the viewport shows, in image pixels.
    public var cropRect: (x: Double, y: Double, side: Double) {
        let side = viewport / displayScale
        let centerX = imageWidth / 2 - offsetX / displayScale
        let centerY = imageHeight / 2 - offsetY / displayScale
        return (centerX - side / 2, centerY - side / 2, side)
    }
}
