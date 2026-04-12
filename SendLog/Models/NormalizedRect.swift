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

    func scaledAroundCenter(x widthScale: CGFloat, y heightScale: CGFloat) -> NormalizedRect {
        let scaledWidth = max(0.01, width * widthScale)
        let scaledHeight = max(0.01, height * heightScale)
        let centerX = x + (width / 2)
        let centerY = y + (height / 2)

        return NormalizedRect(
            x: centerX - (scaledWidth / 2),
            y: centerY - (scaledHeight / 2),
            width: scaledWidth,
            height: scaledHeight
        ).clamped()
    }

    func squareCentered() -> NormalizedRect {
        let clampedCenterX = min(max(0, x + (width / 2)), 1)
        let clampedCenterY = min(max(0, y + (height / 2)), 1)
        let side = min(max(0.01, max(width, height)), 1)
        let originX = min(max(0, clampedCenterX - (side / 2)), 1 - side)
        let originY = min(max(0, clampedCenterY - (side / 2)), 1 - side)

        return NormalizedRect(
            x: originX,
            y: originY,
            width: side,
            height: side
        )
    }

    func squareAnchoredTopLeading() -> NormalizedRect {
        let clampedX = min(max(0, x), 0.99)
        let clampedY = min(max(0, y), 0.99)
        let maxSide = max(0.01, min(1 - clampedX, 1 - clampedY))
        let side = min(max(0.01, max(width, height)), maxSide)

        return NormalizedRect(
            x: clampedX,
            y: clampedY,
            width: side,
            height: side
        )
    }

    static func square(centeredAt point: CGPoint, side: CGFloat) -> NormalizedRect {
        NormalizedRect(
            x: point.x - (side / 2),
            y: point.y - (side / 2),
            width: side,
            height: side
        ).squareCentered()
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
