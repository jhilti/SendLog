import Foundation

enum HoldSource: String, Codable {
    case detected
    case manual
}

struct Hold: Identifiable, Codable, Hashable {
    let id: UUID
    var rect: NormalizedRect
    var contour: [NormalizedPoint]?
    var confidence: Double
    var source: HoldSource

    init(
        id: UUID = UUID(),
        rect: NormalizedRect,
        contour: [NormalizedPoint]? = nil,
        confidence: Double,
        source: HoldSource
    ) {
        self.id = id
        self.rect = rect
        self.contour = contour
        self.confidence = confidence
        self.source = source
    }
}
