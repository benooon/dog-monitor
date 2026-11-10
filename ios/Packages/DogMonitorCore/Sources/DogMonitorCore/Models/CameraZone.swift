import Foundation

/// A point in normalized image coordinates (0...1, origin top-left).
public struct NormalizedPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

/// A closed polygon over the camera image.
public struct ZonePolygon: Codable, Sendable, Hashable {
    public var points: [NormalizedPoint]

    public init(points: [NormalizedPoint]) {
        self.points = points
    }

    public init(rect: NormalizedRect) {
        points = [
            NormalizedPoint(x: rect.x, y: rect.y),
            NormalizedPoint(x: rect.x + rect.width, y: rect.y),
            NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height),
            NormalizedPoint(x: rect.x, y: rect.y + rect.height),
        ]
    }

    /// A polygon needs at least three points (the backend rejects fewer).
    public var isValid: Bool { points.count >= 3 && points.count <= CameraZone.maxPoints }

    /// Even-odd ray casting.
    public func contains(x: Double, y: Double) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// A zone drawn in camera setup (SPEC §4 Calibration), stored by the backend per camera.
public struct CameraZone: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case door, forbidden, bed
    }

    public static let maxPoints = 32
    public static let maxZones = 20

    public var id: UUID
    public var kind: Kind
    public var polygon: ZonePolygon

    public init(id: UUID = UUID(), kind: Kind, polygon: ZonePolygon) {
        self.id = id
        self.kind = kind
        self.polygon = polygon
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, polygon
    }

    // Wire format: {"id", "kind", "polygon": [{"x","y"}]} — the polygon is a bare point array.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        polygon = ZonePolygon(points: try container.decode([NormalizedPoint].self, forKey: .polygon))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(polygon.points, forKey: .polygon)
    }
}

/// Body and response of `GET` / `PUT /device/zones`.
public struct CameraZonesDTO: Codable, Sendable, Hashable {
    public var zones: [CameraZone]

    public init(zones: [CameraZone]) {
        self.zones = zones
    }
}
