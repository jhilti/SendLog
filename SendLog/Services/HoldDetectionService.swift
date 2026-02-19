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
    private struct ContourCandidate {
        let rect: NormalizedRect
        let contour: [NormalizedPoint]
    }

    func detectHolds(in image: UIImage) async throws -> [Hold] {
        guard let cgImage = image.cgImage else {
            throw HoldDetectionError.cgImageUnavailable
        }

        return try await runInBackground {
            let candidates = try contourCandidates(
                in: cgImage,
                maximumImageDimension: 1536,
                contrastAdjustments: [1.0, 1.3],
                darkOnLightModes: [false, true]
            )
            let filtered = filteredAutoCandidates(candidates)
            let deduplicated = deduplicatedCandidates(filtered, iouThreshold: 0.72)
            let holds = deduplicated.prefix(220).map { candidate in
                let area = candidate.rect.width * candidate.rect.height
                let confidence = min(1, Double(area * 22))
                return Hold(
                    rect: candidate.rect,
                    contour: candidate.contour.isEmpty ? nil : candidate.contour,
                    confidence: confidence,
                    source: .detected
                )
            }

            if holds.isEmpty {
                throw HoldDetectionError.noContours
            }

            return holds
        }
    }

    func segmentHold(around normalizedPoint: CGPoint, in image: UIImage) async throws -> Hold? {
        guard let cgImage = image.cgImage else {
            throw HoldDetectionError.cgImageUnavailable
        }

        let point = CGPoint(
            x: min(max(0, normalizedPoint.x), 1),
            y: min(max(0, normalizedPoint.y), 1)
        )

        return try await runInBackground {
            let candidates = try contourCandidates(
                in: cgImage,
                maximumImageDimension: 1800,
                contrastAdjustments: [1.0, 1.35, 1.65],
                darkOnLightModes: [false, true]
            )
            guard let best = bestSegmentationCandidate(around: point, from: candidates) else {
                return nil
            }

            return Hold(
                rect: best.rect,
                contour: best.contour.isEmpty ? nil : best.contour,
                confidence: 1.0,
                source: .manual
            )
        }
    }

    private func runInBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func contourCandidates(
        in cgImage: CGImage,
        maximumImageDimension: Int,
        contrastAdjustments: [Float],
        darkOnLightModes: [Bool]
    ) throws -> [ContourCandidate] {
        var candidates: [ContourCandidate] = []
        candidates.reserveCapacity(800)

        for contrast in contrastAdjustments {
            for darkOnLight in darkOnLightModes {
                let request = VNDetectContoursRequest()
                request.contrastAdjustment = contrast
                request.detectsDarkOnLight = darkOnLight
                request.maximumImageDimension = maximumImageDimension

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try handler.perform([request])

                guard let observation = request.results?.first else {
                    continue
                }

                for contour in observation.topLevelContours {
                    collectCandidates(for: contour, into: &candidates)
                }
            }
        }

        return candidates
    }

    private func collectCandidates(for contour: VNContour, into output: inout [ContourCandidate]) {
        let boundingRect = contour.normalizedPath.boundingBox
        if boundingRect.width > 0 && boundingRect.height > 0 {
            output.append(
                ContourCandidate(
                    rect: NormalizedRect.fromVisionRect(boundingRect),
                    contour: contourPoints(from: contour)
                )
            )
        }

        for child in contour.childContours {
            collectCandidates(for: child, into: &output)
        }
    }

    private func contourPoints(from contour: VNContour) -> [NormalizedPoint] {
        let points = contour.normalizedPoints.map { point in
            NormalizedPoint(
                x: CGFloat(point.x),
                y: 1 - CGFloat(point.y)
            ).clamped()
        }

        guard points.count >= 3 else {
            return []
        }

        return decimated(points, maxCount: 96)
    }

    private func filteredAutoCandidates(_ candidates: [ContourCandidate]) -> [ContourCandidate] {
        candidates.filter { candidate in
            let rect = candidate.rect
            let area = rect.width * rect.height
            let aspect = max(
                rect.width / max(rect.height, 0.0001),
                rect.height / max(rect.width, 0.0001)
            )

            return rect.width > 0.02
                && rect.height > 0.02
                && rect.width < 0.34
                && rect.height < 0.34
                && area > 0.0008
                && area < 0.08
                && aspect < 5
        }
    }

    private func filteredSegmentationCandidates(_ candidates: [ContourCandidate]) -> [ContourCandidate] {
        candidates.filter { candidate in
            let rect = candidate.rect
            let area = rect.width * rect.height
            let aspect = max(
                rect.width / max(rect.height, 0.0001),
                rect.height / max(rect.width, 0.0001)
            )

            return rect.width > 0.012
                && rect.height > 0.012
                && rect.width < 0.45
                && rect.height < 0.45
                && area > 0.0002
                && area < 0.14
                && aspect < 6
        }
    }

    private func bestSegmentationCandidate(
        around point: CGPoint,
        from candidates: [ContourCandidate]
    ) -> ContourCandidate? {
        let filtered = filteredSegmentationCandidates(candidates)
        let deduplicated = deduplicatedCandidates(filtered, iouThreshold: 0.78)

        let scored = deduplicated
            .map { candidate in
                (candidate: candidate, score: segmentationScore(for: candidate, around: point))
            }
            .sorted { left, right in
                left.score > right.score
            }

        guard let best = scored.first, best.score > 1 else {
            return nil
        }

        return best.candidate
    }

    private func segmentationScore(for candidate: ContourCandidate, around point: CGPoint) -> CGFloat {
        let rect = candidate.rect.cgRect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let distance = hypot(center.x - point.x, center.y - point.y)
        let distanceScore = max(0, 1 - (distance / 0.28))
        let area = rect.width * rect.height
        let targetArea: CGFloat = 0.012
        let areaScore = max(0, 1 - abs(area - targetArea) / 0.08)

        let containsContour = contourContains(point, in: candidate.contour)
        let containsRect = rect.contains(point)

        var score = (distanceScore * 0.9) + (areaScore * 0.25)
        if containsRect {
            score += 0.8
        }
        if containsContour {
            score += 1.2
        }
        if !containsRect && !containsContour && distance > 0.13 {
            score -= 0.7
        }
        return score
    }

    private func contourContains(_ point: CGPoint, in contour: [NormalizedPoint]) -> Bool {
        guard contour.count >= 3 else {
            return false
        }

        let path = CGMutablePath()
        path.move(to: contour[0].cgPoint)
        for contourPoint in contour.dropFirst() {
            path.addLine(to: contourPoint.cgPoint)
        }
        path.closeSubpath()
        return path.contains(point)
    }

    private func decimated(_ points: [NormalizedPoint], maxCount: Int) -> [NormalizedPoint] {
        guard maxCount > 2, points.count > maxCount else {
            return points
        }

        var result: [NormalizedPoint] = []
        result.reserveCapacity(maxCount)
        let step = Double(points.count - 1) / Double(maxCount - 1)
        for index in 0..<maxCount {
            let sourceIndex = min(
                Int(round(Double(index) * step)),
                points.count - 1
            )
            result.append(points[sourceIndex])
        }
        return result
    }

    private func deduplicatedCandidates(
        _ candidates: [ContourCandidate],
        iouThreshold: CGFloat
    ) -> [ContourCandidate] {
        var result: [ContourCandidate] = []
        let sorted = candidates.sorted { left, right in
            (left.rect.width * left.rect.height) > (right.rect.width * right.rect.height)
        }

        for candidate in sorted {
            if result.contains(where: { existing in
                intersectionOverUnion(candidate.rect, existing.rect) > iouThreshold
            }) {
                continue
            }
            result.append(candidate)
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
