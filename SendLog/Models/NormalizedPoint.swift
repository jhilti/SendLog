import CoreGraphics
import Foundation

struct NormalizedPoint: Codable, Hashable {
    var x: CGFloat
    var y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    func clamped() -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(0, x), 1),
            y: min(max(0, y), 1)
        )
    }

    func toCGPoint(in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + (x * imageFrame.width),
            y: imageFrame.minY + (y * imageFrame.height)
        )
    }
}
