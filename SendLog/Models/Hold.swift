import Foundation

struct Hold: Identifiable, Codable, Hashable {
    let id: UUID
    var rect: NormalizedRect
    var contour: [NormalizedPoint]?
    var confidence: Double

    init(
        id: UUID = UUID(),
        rect: NormalizedRect,
        contour: [NormalizedPoint]? = nil,
        confidence: Double
    ) {
        self.id = id
        self.rect = rect
        self.contour = contour
        self.confidence = confidence
    }
}
