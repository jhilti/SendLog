import Foundation
import UIKit
import Vision

enum HoldDetectionError: LocalizedError {
    case cgImageUnavailable
    case noContours

    var errorDescription: String? {
        switch self {
        case .cgImageUnavailable:
            return "The selected wall image could not be processed."
        case .noContours:
            return "No holds were detected. Try adding holds manually."
        }
    }
}

struct HoldDetectionService {
    func detectHolds(in image: UIImage) async throws -> [Hold] {
        guard let cgImage = image.cgImage else {
            throw HoldDetectionError.cgImageUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNDetectContoursRequest()
                    request.contrastAdjustment = 1.0
                    request.detectsDarkOnLight = false
                    request.maximumImageDimension = 1024

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])

                    guard let observation = request.results?.first else {
                        throw HoldDetectionError.noContours
                    }

                    let holds = self.holds(from: observation)
                    if holds.isEmpty {
                        throw HoldDetectionError.noContours
                    }

                    continuation.resume(returning: holds)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func holds(from observation: VNContoursObservation) -> [Hold] {
        var candidateRects: [NormalizedRect] = []
        for contour in observation.topLevelContours {
            collectBoundingRects(for: contour, into: &candidateRects)
        }

        let filtered = candidateRects.filter { rect in
            let area = rect.width * rect.height
            return rect.width > 0.02
                && rect.height > 0.02
                && rect.width < 0.35
                && rect.height < 0.35
                && area > 0.0008
                && area < 0.08
        }

        let deduplicated = deduplicatedRects(filtered)
        return deduplicated.prefix(220).map { rect in
            let confidence = min(1, Double((rect.width * rect.height) * 20))
            return Hold(rect: rect, confidence: confidence, source: .detected)
        }
    }

    private func collectBoundingRects(for contour: VNContour, into output: inout [NormalizedRect]) {
        let boundingRect = contour.normalizedPath.boundingBox
        if boundingRect.width > 0 && boundingRect.height > 0 {
            output.append(NormalizedRect.fromVisionRect(boundingRect))
        }

        for child in contour.childContours {
            collectBoundingRects(for: child, into: &output)
        }
    }

    private func deduplicatedRects(_ rects: [NormalizedRect]) -> [NormalizedRect] {
        var result: [NormalizedRect] = []
        let sorted = rects.sorted { left, right in
            (left.width * left.height) > (right.width * right.height)
        }

        for rect in sorted {
            if result.contains(where: { intersectionOverUnion(rect, $0) > 0.72 }) {
                continue
            }
            result.append(rect)
        }

        return result
    }

    private func intersectionOverUnion(_ a: NormalizedRect, _ b: NormalizedRect) -> CGFloat {
        let rectA = a.cgRect
        let rectB = b.cgRect
        let intersection = rectA.intersection(rectB)
        if intersection.isNull {
            return 0
        }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = (rectA.width * rectA.height) + (rectB.width * rectB.height) - intersectionArea
        guard unionArea > 0 else {
            return 0
        }
        return intersectionArea / unionArea
    }
}
