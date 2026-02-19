import CoreGraphics
import Foundation

struct NormalizedRect: Codable, Hashable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func clamped() -> NormalizedRect {
        let clampedX = min(max(0, x), 1)
        let clampedY = min(max(0, y), 1)
        let clampedWidth = min(max(0.01, width), 1 - clampedX)
        let clampedHeight = min(max(0.01, height), 1 - clampedY)
        return NormalizedRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    func toCGRect(in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + (x * imageFrame.width),
            y: imageFrame.minY + (y * imageFrame.height),
            width: width * imageFrame.width,
            height: height * imageFrame.height
        )
    }

    static func fromVisionRect(_ visionRect: CGRect) -> NormalizedRect {
        let converted = NormalizedRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
        return converted.clamped()
    }
}
