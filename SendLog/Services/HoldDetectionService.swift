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

    private struct WallRegion {
        let contour: [CGPoint]
        let boundingRect: CGRect
    }

    private struct AppearanceMetrics {
        let colorDelta: Double
        let saturationDelta: Double
        let valueDrop: Double
        let innerSaturation: Double
        let innerValue: Double
    }

    private struct PixelStats {
        let red: Double
        let green: Double
        let blue: Double
        let saturation: Double
        let value: Double
        let sampleCount: Int
    }

    private struct PixelRect {
        let minX: Int
        let minY: Int
        let maxX: Int // exclusive
        let maxY: Int // exclusive
    }

    private struct PixelSampler {
        private let width: Int
        private let height: Int
        private let bytesPerRow: Int
        private let data: [UInt8]

        init?(cgImage: CGImage, maxDimension: Int = 960) {
            let sourceWidth = cgImage.width
            let sourceHeight = cgImage.height
            guard sourceWidth > 0, sourceHeight > 0 else {
                return nil
            }

            let scale = min(1, CGFloat(maxDimension) / CGFloat(max(sourceWidth, sourceHeight)))
            let scaledWidth = max(1, Int(round(CGFloat(sourceWidth) * scale)))
            let scaledHeight = max(1, Int(round(CGFloat(sourceHeight) * scale)))
            let rowBytes = scaledWidth * 4

            var imageBytes = Data(count: rowBytes * scaledHeight)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

            let drewImage: Bool = imageBytes.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress,
                      let context = CGContext(
                        data: baseAddress,
                        width: scaledWidth,
                        height: scaledHeight,
                        bitsPerComponent: 8,
                        bytesPerRow: rowBytes,
                        space: colorSpace,
                        bitmapInfo: bitmapInfo
                      ) else {
                    return false
                }

                context.interpolationQuality = .medium
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
                return true
            }

            guard drewImage else {
                return nil
            }

            width = scaledWidth
            height = scaledHeight
            bytesPerRow = rowBytes
            data = [UInt8](imageBytes)
        }

        func stats(in normalizedRect: CGRect) -> PixelStats? {
            guard let rect = pixelRect(for: normalizedRect) else {
                return nil
            }
            return stats(in: rect)
        }

        func ringStats(inner normalizedInnerRect: CGRect, outer normalizedOuterRect: CGRect) -> PixelStats? {
            guard let inner = pixelRect(for: normalizedInnerRect),
                  let outer = pixelRect(for: normalizedOuterRect) else {
                return nil
            }

            var sumR = 0.0
            var sumG = 0.0
            var sumB = 0.0
            var sumS = 0.0
            var sumV = 0.0
            var count = 0

            for y in outer.minY..<outer.maxY {
                for x in outer.minX..<outer.maxX {
                    if x >= inner.minX && x < inner.maxX && y >= inner.minY && y < inner.maxY {
                        continue
                    }
                    let index = (y * bytesPerRow) + (x * 4)
                    let r = Double(data[index]) / 255.0
                    let g = Double(data[index + 1]) / 255.0
                    let b = Double(data[index + 2]) / 255.0
                    let hsv = Self.rgbToHSV(r: r, g: g, b: b)

                    sumR += r
                    sumG += g
                    sumB += b
                    sumS += hsv.s
                    sumV += hsv.v
                    count += 1
                }
            }

            guard count > 0 else {
                return nil
            }
            let countAsDouble = Double(count)
            return PixelStats(
                red: sumR / countAsDouble,
                green: sumG / countAsDouble,
                blue: sumB / countAsDouble,
                saturation: sumS / countAsDouble,
                value: sumV / countAsDouble,
                sampleCount: count
            )
        }

        private func stats(in rect: PixelRect) -> PixelStats? {
            var sumR = 0.0
            var sumG = 0.0
            var sumB = 0.0
            var sumS = 0.0
            var sumV = 0.0
            var count = 0

            for y in rect.minY..<rect.maxY {
                for x in rect.minX..<rect.maxX {
                    let index = (y * bytesPerRow) + (x * 4)
                    let r = Double(data[index]) / 255.0
                    let g = Double(data[index + 1]) / 255.0
                    let b = Double(data[index + 2]) / 255.0
                    let hsv = Self.rgbToHSV(r: r, g: g, b: b)

                    sumR += r
                    sumG += g
                    sumB += b
                    sumS += hsv.s
                    sumV += hsv.v
                    count += 1
                }
            }

            guard count > 0 else {
                return nil
            }
            let countAsDouble = Double(count)
            return PixelStats(
                red: sumR / countAsDouble,
                green: sumG / countAsDouble,
                blue: sumB / countAsDouble,
                saturation: sumS / countAsDouble,
                value: sumV / countAsDouble,
                sampleCount: count
            )
        }

        private func pixelRect(for normalizedRect: CGRect) -> PixelRect? {
            let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            let clamped = normalizedRect.standardized.intersection(unitRect)
            guard !clamped.isNull, clamped.width > 0.001, clamped.height > 0.001 else {
                return nil
            }

            let minX = max(0, Int(floor(clamped.minX * CGFloat(width))))
            let maxX = min(width, Int(ceil(clamped.maxX * CGFloat(width))))
            let minY = max(0, Int(floor(clamped.minY * CGFloat(height))))
            let maxY = min(height, Int(ceil(clamped.maxY * CGFloat(height))))

            guard maxX - minX >= 2, maxY - minY >= 2 else {
                return nil
            }

            return PixelRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        }

        private static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
            let maxValue = max(r, g, b)
            let minValue = min(r, g, b)
            let delta = maxValue - minValue

            let hue: Double
            if delta == 0 {
                hue = 0
            } else if maxValue == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) / 6
            } else if maxValue == g {
                hue = (((b - r) / delta) + 2) / 6
            } else {
                hue = (((r - g) / delta) + 4) / 6
            }

            let normalizedHue = hue < 0 ? hue + 1 : hue
            let saturation = maxValue == 0 ? 0 : (delta / maxValue)
            return (h: normalizedHue, s: saturation, v: maxValue)
        }
    }

    func detectHolds(in image: UIImage) async throws -> [Hold] {
        guard let cgImage = image.cgImage else {
            throw HoldDetectionError.cgImageUnavailable
        }

        return try await runInBackground {
            let wallRegion = detectWallRegion(in: cgImage)
            let salientRegions = detectSalientRegions(in: cgImage)
            let candidates = try contourCandidates(
                in: cgImage,
                maximumImageDimension: 1536,
                contrastAdjustments: [1.0, 1.2, 1.4],
                darkOnLightModes: [false, true],
                wallRegion: wallRegion
            )

            let sampler = PixelSampler(cgImage: cgImage)
            let filtered = filteredAutoCandidates(
                candidates,
                wallRegion: wallRegion,
                salientRegions: salientRegions,
                sampler: sampler
            )
            let deduplicated = deduplicatedCandidates(filtered, iouThreshold: 0.55)
            let detectedHolds = holds(from: deduplicated, limit: 75)

            if !detectedHolds.isEmpty {
                return detectedHolds
            }

            // Relaxed fallback to avoid empty results on difficult images.
            let fallbackCandidates: [ContourCandidate]
            if wallRegion != nil {
                fallbackCandidates = try contourCandidates(
                    in: cgImage,
                    maximumImageDimension: 1536,
                    contrastAdjustments: [1.0, 1.3],
                    darkOnLightModes: [false, true],
                    wallRegion: nil
                )
            } else {
                fallbackCandidates = candidates
            }

            let relaxed = filteredAutoCandidates(
                fallbackCandidates,
                wallRegion: nil,
                salientRegions: salientRegions,
                sampler: nil
            )
            let relaxedDeduplicated = deduplicatedCandidates(relaxed, iouThreshold: 0.60)
            let relaxedHolds = holds(from: relaxedDeduplicated, limit: 75)
            if relaxedHolds.isEmpty {
                throw HoldDetectionError.noContours
            }

            return relaxedHolds
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
            let wallRegion = detectWallRegion(in: cgImage)
            let candidates = try contourCandidates(
                in: cgImage,
                maximumImageDimension: 1400,
                contrastAdjustments: [1.0, 1.2, 1.4],
                darkOnLightModes: [false, true],
                wallRegion: wallRegion
            )

            let sampler = PixelSampler(cgImage: cgImage)
            let filtered = filteredSegmentationCandidates(candidates, wallRegion: wallRegion, sampler: sampler)
            guard let best = bestSegmentationCandidate(around: point, from: filtered) else {
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

    private func holds(from candidates: [ContourCandidate], limit: Int) -> [Hold] {
        candidates.prefix(limit).map { candidate in
            let rect = tightenedRect(candidate.rect, insetRatio: 0.22)
            let area = rect.width * rect.height
            let confidence = min(1, Double(max(0.2, area * 30)))
            return Hold(
                rect: rect,
                contour: nil, // Auto-detected raw contours are often shadow-biased; use tighter marker rects.
                confidence: confidence,
                source: .detected
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

    private func detectWallRegion(in cgImage: CGImage) -> WallRegion? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 8
        request.minimumSize = 0.18
        request.minimumConfidence = 0.45
        request.minimumAspectRatio = 0.20
        request.maximumAspectRatio = 2.20
        request.quadratureTolerance = 45

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        return observations
            .compactMap { wallRegion(from: $0) }
            .max(by: { wallScore($0) < wallScore($1) })
    }

    private func wallRegion(from observation: VNRectangleObservation) -> WallRegion? {
        let points = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            .map { point in
                CGPoint(x: CGFloat(point.x), y: 1 - CGFloat(point.y))
            }

        let rect = boundingRect(for: points)
        guard rect.width > 0.12, rect.height > 0.12 else {
            return nil
        }

        return WallRegion(contour: points, boundingRect: rect)
    }

    private func wallScore(_ region: WallRegion) -> CGFloat {
        let area = region.boundingRect.width * region.boundingRect.height
        let distanceToCenter = hypot(region.boundingRect.midX - 0.5, region.boundingRect.midY - 0.5)
        return area - (distanceToCenter * 0.22)
    }

    private func detectSalientRegions(in cgImage: CGImage) -> [CGRect] {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        request.usesCPUOnly = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observation = request.results?.first else {
            return []
        }

        let boxes = observation.salientObjects ?? []
        return boxes
            .map { observation in
                let visionRect = observation.boundingBox
                return CGRect(
                    x: visionRect.minX,
                    y: 1 - visionRect.maxY,
                    width: visionRect.width,
                    height: visionRect.height
                ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            .filter { !$0.isNull && $0.width > 0.01 && $0.height > 0.01 }
    }

    private func contourCandidates(
        in cgImage: CGImage,
        maximumImageDimension: Int,
        contrastAdjustments: [Float],
        darkOnLightModes: [Bool],
        wallRegion: WallRegion?
    ) throws -> [ContourCandidate] {
        var candidates: [ContourCandidate] = []
        candidates.reserveCapacity(800)
        let regionOfInterest = wallRegion.map { visionRect(fromTopLeftNormalizedRect: $0.boundingRect) }

        for contrast in contrastAdjustments {
            for darkOnLight in darkOnLightModes {
                let request = VNDetectContoursRequest()
                request.contrastAdjustment = contrast
                request.detectsDarkOnLight = darkOnLight
                request.maximumImageDimension = maximumImageDimension
                if let regionOfInterest, regionOfInterest.width > 0, regionOfInterest.height > 0 {
                    request.regionOfInterest = regionOfInterest
                }

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

    private func filteredAutoCandidates(
        _ candidates: [ContourCandidate],
        wallRegion: WallRegion?,
        salientRegions: [CGRect],
        sampler: PixelSampler?
    ) -> [ContourCandidate] {
        candidates.filter { candidate in
            let rect = candidate.rect
            let area = rect.width * rect.height
            let aspect = max(
                rect.width / max(rect.height, 0.0001),
                rect.height / max(rect.width, 0.0001)
            )
            let contourArea = normalizedContourArea(candidate.contour)
            let fillRatio = area > 0 ? contourArea / area : 0
            let compactness = contourCompactness(area: contourArea, contour: candidate.contour)

            guard rect.width > 0.020
                    && rect.height > 0.020
                    && rect.width < 0.30
                    && rect.height < 0.30
                    && area > 0.0009
                    && area < 0.040
                    && aspect < 4.0 else {
                return false
            }

            guard fillRatio > 0.30 else {
                return false
            }

            guard compactness > 0.080 else {
                return false
            }

            if area > 0.018 && fillRatio < 0.36 {
                return false
            }

            if aspect > 2.5 && compactness < 0.16 {
                return false
            }

            guard passesWallFilter(candidate, wallRegion: wallRegion) else {
                return false
            }

            guard passesSaliencyFilter(candidate, salientRegions: salientRegions) else {
                return false
            }

            if let sampler, !passesAutoAppearanceFilter(candidate, sampler: sampler) {
                return false
            }

            return true
        }
    }

    private func filteredSegmentationCandidates(
        _ candidates: [ContourCandidate],
        wallRegion: WallRegion?,
        sampler: PixelSampler?
    ) -> [ContourCandidate] {
        candidates.filter { candidate in
            let rect = candidate.rect
            let area = rect.width * rect.height
            let aspect = max(
                rect.width / max(rect.height, 0.0001),
                rect.height / max(rect.width, 0.0001)
            )
            let contourArea = normalizedContourArea(candidate.contour)
            let fillRatio = area > 0 ? contourArea / area : 0
            let compactness = contourCompactness(area: contourArea, contour: candidate.contour)

            guard rect.width > 0.016
                    && rect.height > 0.016
                    && rect.width < 0.45
                    && rect.height < 0.45
                    && area > 0.00045
                    && area < 0.12
                    && aspect < 5.5 else {
                return false
            }

            guard fillRatio > 0.08 else {
                return false
            }

            guard compactness > 0.012 else {
                return false
            }

            guard passesWallFilter(candidate, wallRegion: wallRegion) else {
                return false
            }

            if let sampler, !passesSegmentationAppearanceFilter(candidate, sampler: sampler) {
                return false
            }

            return true
        }
    }

    private func passesWallFilter(_ candidate: ContourCandidate, wallRegion: WallRegion?) -> Bool {
        guard let wallRegion else {
            return true
        }

        let rect = candidate.rect.cgRect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if pointInPolygon(center, polygon: wallRegion.contour) {
            return true
        }

        if pointInPolygon(CGPoint(x: rect.minX, y: rect.minY), polygon: wallRegion.contour) {
            return true
        }
        if pointInPolygon(CGPoint(x: rect.maxX, y: rect.minY), polygon: wallRegion.contour) {
            return true
        }
        if pointInPolygon(CGPoint(x: rect.maxX, y: rect.maxY), polygon: wallRegion.contour) {
            return true
        }
        if pointInPolygon(CGPoint(x: rect.minX, y: rect.maxY), polygon: wallRegion.contour) {
            return true
        }

        return false
    }

    private func passesSaliencyFilter(_ candidate: ContourCandidate, salientRegions: [CGRect]) -> Bool {
        guard !salientRegions.isEmpty else {
            return true
        }

        let rect = candidate.rect.cgRect
        let center = CGPoint(x: rect.midX, y: rect.midY)

        if salientRegions.contains(where: { $0.contains(center) }) {
            return true
        }

        let expanded = rect.insetBy(dx: -rect.width * 0.35, dy: -rect.height * 0.35)
        return salientRegions.contains(where: { $0.intersects(expanded) })
    }

    private func passesAutoAppearanceFilter(_ candidate: ContourCandidate, sampler: PixelSampler) -> Bool {
        guard let metrics = appearanceMetrics(for: candidate, sampler: sampler) else {
            return true
        }

        if metrics.innerValue < 0.08 {
            return false
        }

        // Common shadow pattern: low color shift and mainly a brightness drop.
        if metrics.colorDelta < 0.05 && metrics.saturationDelta < 0.02 && metrics.valueDrop > 0.05 {
            return false
        }

        let score =
            (metrics.colorDelta * 2.2)
            + (max(0, metrics.saturationDelta) * 1.8)
            + (metrics.innerSaturation * 0.35)
            - (max(0, metrics.valueDrop - 0.03) * 2.4)

        if metrics.colorDelta < 0.09 && metrics.saturationDelta < 0.04 {
            return false
        }

        if metrics.innerSaturation < 0.12 && metrics.colorDelta < 0.14 {
            return false
        }

        return score > 0.32
    }

    private func passesSegmentationAppearanceFilter(_ candidate: ContourCandidate, sampler: PixelSampler) -> Bool {
        guard let metrics = appearanceMetrics(for: candidate, sampler: sampler) else {
            return true
        }

        if metrics.colorDelta < 0.04 && metrics.saturationDelta < 0.015 && metrics.valueDrop > 0.07 {
            return false
        }

        let score =
            (metrics.colorDelta * 1.9)
            + (max(0, metrics.saturationDelta) * 1.2)
            - (max(0, metrics.valueDrop - 0.04) * 1.6)

        return score > 0.12
    }

    private func appearanceMetrics(for candidate: ContourCandidate, sampler: PixelSampler) -> AppearanceMetrics? {
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let baseRect = candidate.rect.cgRect.intersection(unitRect)
        guard !baseRect.isNull else {
            return nil
        }

        let innerInsetX = baseRect.width * 0.08
        let innerInsetY = baseRect.height * 0.08
        let innerRect = baseRect
            .insetBy(dx: innerInsetX, dy: innerInsetY)
            .intersection(unitRect)

        let innerSampleRect: CGRect
        if !innerRect.isNull, innerRect.width > 0.003, innerRect.height > 0.003 {
            innerSampleRect = innerRect
        } else {
            innerSampleRect = baseRect
        }

        let outerRect = expandedRect(baseRect, scale: 1.8)
        guard let inner = sampler.stats(in: innerSampleRect),
              let ring = sampler.ringStats(inner: baseRect, outer: outerRect),
              inner.sampleCount > 10,
              ring.sampleCount > 20 else {
            return nil
        }

        let colorDelta = hypot(
            hypot(inner.red - ring.red, inner.green - ring.green),
            inner.blue - ring.blue
        )

        return AppearanceMetrics(
            colorDelta: colorDelta,
            saturationDelta: inner.saturation - ring.saturation,
            valueDrop: ring.value - inner.value,
            innerSaturation: inner.saturation,
            innerValue: inner.value
        )
    }

    private func expandedRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let newWidth = min(1, rect.width * scale)
        let newHeight = min(1, rect.height * scale)
        let expanded = CGRect(
            x: center.x - (newWidth / 2),
            y: center.y - (newHeight / 2),
            width: newWidth,
            height: newHeight
        )
        return expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func tightenedRect(_ rect: NormalizedRect, insetRatio: CGFloat) -> NormalizedRect {
        let cgRect = rect.cgRect
        let dx = cgRect.width * insetRatio
        let dy = cgRect.height * insetRatio
        let tightened = cgRect.insetBy(dx: dx, dy: dy)
        let fallback = cgRect
        let resolved = (tightened.width > 0.008 && tightened.height > 0.008) ? tightened : fallback
        return NormalizedRect(
            x: resolved.minX,
            y: resolved.minY,
            width: resolved.width,
            height: resolved.height
        ).clamped()
    }

    private func bestSegmentationCandidate(
        around point: CGPoint,
        from candidates: [ContourCandidate]
    ) -> ContourCandidate? {
        let deduplicated = deduplicatedCandidates(candidates, iouThreshold: 0.78)

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

    private func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }

        var contains = false
        var previousIndex = polygon.count - 1

        for index in polygon.indices {
            let current = polygon[index]
            let previous = polygon[previousIndex]

            let intersects = ((current.y > point.y) != (previous.y > point.y))
                && (point.x < (previous.x - current.x) * (point.y - current.y)
                        / ((previous.y - current.y) + 0.000001) + current.x)

            if intersects {
                contains.toggle()
            }

            previousIndex = index
        }

        return contains
    }

    private func normalizedContourArea(_ contour: [NormalizedPoint]) -> CGFloat {
        guard contour.count >= 3 else {
            return 0
        }

        var area: CGFloat = 0
        for index in 0..<contour.count {
            let current = contour[index].cgPoint
            let next = contour[(index + 1) % contour.count].cgPoint
            area += (current.x * next.y) - (next.x * current.y)
        }
        return abs(area) * 0.5
    }

    private func normalizedContourPerimeter(_ contour: [NormalizedPoint]) -> CGFloat {
        guard contour.count >= 2 else {
            return 0
        }

        var perimeter: CGFloat = 0
        for index in 0..<contour.count {
            let current = contour[index].cgPoint
            let next = contour[(index + 1) % contour.count].cgPoint
            perimeter += hypot(next.x - current.x, next.y - current.y)
        }
        return perimeter
    }

    private func contourCompactness(area: CGFloat, contour: [NormalizedPoint]) -> CGFloat {
        guard area > 0 else {
            return 0
        }
        let perimeter = normalizedContourPerimeter(contour)
        guard perimeter > 0 else {
            return 0
        }

        let compactness = (4 * CGFloat.pi * area) / (perimeter * perimeter)
        return min(1, max(0, compactness))
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
            candidatePriority(left) > candidatePriority(right)
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

    private func candidatePriority(_ candidate: ContourCandidate) -> CGFloat {
        let area = candidate.rect.width * candidate.rect.height
        let targetArea: CGFloat = 0.0065
        let areaScore = max(0, 1 - abs(area - targetArea) / 0.04)
        let aspect = max(
            candidate.rect.width / max(candidate.rect.height, 0.0001),
            candidate.rect.height / max(candidate.rect.width, 0.0001)
        )
        let aspectScore = max(0, 1 - (aspect - 1) / 5)
        let contourScore = min(1, CGFloat(candidate.contour.count) / 80)
        let contourArea = normalizedContourArea(candidate.contour)
        let fillRatio = area > 0 ? min(1, contourArea / area) : 0
        let compactness = contourCompactness(area: contourArea, contour: candidate.contour)
        return (areaScore * 0.4)
            + (aspectScore * 0.2)
            + (contourScore * 0.1)
            + (fillRatio * 0.15)
            + (compactness * 0.15)
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

    private func visionRect(fromTopLeftNormalizedRect rect: CGRect) -> CGRect {
        let converted = CGRect(
            x: rect.minX,
            y: 1 - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        return converted.intersection(unitRect)
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else {
            return .zero
        }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

extension HoldDetectionService: HoldDetecting {}
