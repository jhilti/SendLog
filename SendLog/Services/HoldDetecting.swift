import CoreGraphics
import UIKit

protocol HoldDetecting {
    func detectHolds(in image: UIImage) async throws -> [Hold]
    func segmentHold(around normalizedPoint: CGPoint, in image: UIImage) async throws -> Hold?
}
