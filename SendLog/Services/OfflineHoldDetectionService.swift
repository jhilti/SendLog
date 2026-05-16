import CoreGraphics
import CoreML
import UIKit

struct OfflineHoldDetectionService {
    struct DetectionResult {
        let holds: [Hold]
        let wallEdges: [[NormalizedPoint]]
    }

    enum DetectionError: LocalizedError {
        case modelNotFound
        case imagePreparationFailed
        case invalidModelOutput

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "The offline hold detection model is missing from the app bundle."
            case .imagePreparationFailed:
                return "Could not prepare the wall image for hold detection."
            case .invalidModelOutput:
                return "Offline hold detection returned an unexpected result."
            }
        }
    }

    private struct Candidate {
        var rect: CGRect
        var contour: [NormalizedPoint]? = nil
        var confidence: Float
        var coefficients: [Float]
        var holdScore: Float = 0
        var maskPixels: Set<Int> = []

        var area: CGFloat {
            rect.width * rect.height
        }

        var center: CGPoint {
            CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    private static let inputSize = 1024
    private static let protoSize = 256
    private static let predictionName = "var_1057"
    private static let prototypeName = "var_1095"

    private struct ScoreMap {
        var scores: [Float]
        var wallMask: [Bool]
        var wallArea: Int

        func score(x: Int, y: Int) -> Float {
            scores[(y * protoSize) + x]
        }

        func isWall(x: Int, y: Int) -> Bool {
            wallMask[(y * protoSize) + x]
        }
    }

    private struct MaskComponent {
        var indices: [Int]
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
    }

    private struct SizeConstraints {
        var minArea: CGFloat
        var minPerimeter: CGFloat
        var minMinDimension: CGFloat
        var minMaxDimension: CGFloat
        var maxArea: CGFloat
        var maxPerimeter: CGFloat
        var maxDimension: CGFloat
    }

    private struct InputGeometry {
        let imageRect: CGRect

        func modelPoint(fromNormalizedPoint point: CGPoint) -> CGPoint {
            CGPoint(
                x: imageRect.minX + (point.x * imageRect.width),
                y: imageRect.minY + (point.y * imageRect.height)
            )
        }

        func normalizedRect(fromModelRect modelRect: CGRect) -> NormalizedRect? {
            let displayRect = CGRect(
                x: modelRect.minX,
                y: CGFloat(inputSize) - modelRect.maxY,
                width: modelRect.width,
                height: modelRect.height
            ).intersection(imageRect)
            guard !displayRect.isNull, displayRect.width > 0, displayRect.height > 0 else {
                return nil
            }

            return NormalizedRect(
                x: (displayRect.minX - imageRect.minX) / imageRect.width,
                y: (displayRect.minY - imageRect.minY) / imageRect.height,
                width: displayRect.width / imageRect.width,
                height: displayRect.height / imageRect.height
            ).clamped()
        }
    }

    func detectHolds(in image: UIImage, targetCount: Int = 92) async throws -> [Hold] {
        try await Task.detached(priority: .userInitiated) {
            try Self.detectHoldsSynchronously(in: image, targetCount: targetCount)
        }.value
    }

    func detectHoldsAndWallEdges(in image: UIImage, targetCount: Int = 92) async throws -> DetectionResult {
        try await Task.detached(priority: .userInitiated) {
            let holds = try Self.detectHoldsSynchronously(in: image, targetCount: targetCount)
            let wallEdges = Self.estimatedWallEdges(from: holds)
            return DetectionResult(holds: holds, wallEdges: wallEdges)
        }.value
    }

    func detectHold(in image: UIImage, at normalizedPoint: CGPoint) async throws -> Hold? {
        try await Task.detached(priority: .userInitiated) {
            try Self.detectHoldSynchronously(in: image, at: normalizedPoint)
        }.value
    }

    private static func detectHoldsSynchronously(in image: UIImage, targetCount: Int) throws -> [Hold] {
        let geometry = inputGeometry(for: image, size: inputSize)
        let candidates = try candidatesSynchronously(in: image, geometry: geometry)
        let selected = selectCandidates(candidates, targetCount: targetCount)
        return selected.compactMap { candidate in
            hold(from: candidate, geometry: geometry)
        }
    }

    private static func detectHoldSynchronously(in image: UIImage, at normalizedPoint: CGPoint) throws -> Hold? {
        let point = CGPoint(
            x: min(max(0, normalizedPoint.x), 1),
            y: min(max(0, normalizedPoint.y), 1)
        )
        let geometry = inputGeometry(for: image, size: inputSize)
        let displayPoint = geometry.modelPoint(fromNormalizedPoint: point)
        let candidates = try candidatesSynchronously(in: image, geometry: geometry)
        guard let candidate = candidate(atDisplayPoint: displayPoint, in: candidates) else {
            return nil
        }
        return hold(from: candidate, geometry: geometry)
    }

    private static func estimatedWallEdges(from holds: [Hold]) -> [[NormalizedPoint]] {
        guard holds.count >= 6 else {
            return []
        }

        let sortedByY = holds.sorted { $0.rect.y < $1.rect.y }
        let top = max(0, percentile(sortedByY.map { $0.rect.cgRect.minY }, 0.03) - 0.075)
        let bottom = min(1, percentile(sortedByY.map { $0.rect.cgRect.maxY }, 0.97) + 0.075)
        guard bottom - top > 0.18 else {
            return []
        }

        let binCount = 9
        let binHeight = (bottom - top) / CGFloat(binCount)
        var leftPoints: [CGPoint] = []
        var rightPoints: [CGPoint] = []

        for index in 0...binCount {
            let y = top + (CGFloat(index) * binHeight)
            let bandHalfHeight = max(binHeight * 0.85, 0.10)
            let localHolds = holds.filter { hold in
                let centerY = hold.rect.y + (hold.rect.height / 2)
                return abs(centerY - y) <= bandHalfHeight
            }

            guard localHolds.count >= 2 else {
                continue
            }

            let leftValues = localHolds.map { $0.rect.cgRect.minX }.sorted()
            let rightValues = localHolds.map { $0.rect.cgRect.maxX }.sorted()
            let localWidths = localHolds.map(\.rect.width).sorted()
            let margin = max(0.035, min(0.11, percentile(localWidths, 0.70) * 1.9))
            let leftX = max(0, percentile(leftValues, 0.04) - margin)
            let rightX = min(1, percentile(rightValues, 0.96) + margin)

            if rightX - leftX > 0.20 {
                leftPoints.append(CGPoint(x: leftX, y: y))
                rightPoints.append(CGPoint(x: rightX, y: y))
            }
        }

        guard leftPoints.count >= 3, rightPoints.count >= 3 else {
            return []
        }

        let smoothedLeft = smoothedBoundary(leftPoints)
        let smoothedRight = smoothedBoundary(rightPoints)
        guard let firstLeft = smoothedLeft.first,
              let lastLeft = smoothedLeft.last,
              let firstRight = smoothedRight.first,
              let lastRight = smoothedRight.last else {
            return []
        }

        let topEdge = [
            NormalizedPoint(x: firstLeft.x, y: firstLeft.y).clamped(),
            NormalizedPoint(x: firstRight.x, y: firstRight.y).clamped()
        ]
        let rightEdge = smoothedRight.map { NormalizedPoint(x: $0.x, y: $0.y).clamped() }
        let bottomEdge = [
            NormalizedPoint(x: lastRight.x, y: lastRight.y).clamped(),
            NormalizedPoint(x: lastLeft.x, y: lastLeft.y).clamped()
        ]
        let leftEdge = smoothedLeft.reversed().map { NormalizedPoint(x: $0.x, y: $0.y).clamped() }

        return [topEdge, rightEdge, bottomEdge, leftEdge]
    }

    private static func smoothedBoundary(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else {
            return points
        }

        return points.enumerated().map { index, point in
            let lower = max(0, index - 1)
            let upper = min(points.count - 1, index + 1)
            let neighbors = points[lower...upper]
            let averageX = neighbors.map(\.x).reduce(0, +) / CGFloat(neighbors.count)
            return CGPoint(x: (point.x * 0.55) + (averageX * 0.45), y: point.y)
        }
    }

    private static func percentile(_ sortedValues: [CGFloat], _ percentile: CGFloat) -> CGFloat {
        guard !sortedValues.isEmpty else {
            return 0
        }

        let sorted = sortedValues.sorted()
        let clamped = min(max(0, percentile), 1)
        let rawIndex = clamped * CGFloat(sorted.count - 1)
        let lowerIndex = Int(floor(rawIndex))
        let upperIndex = Int(ceil(rawIndex))
        guard lowerIndex != upperIndex else {
            return sorted[lowerIndex]
        }

        let fraction = rawIndex - CGFloat(lowerIndex)
        return sorted[lowerIndex] + ((sorted[upperIndex] - sorted[lowerIndex]) * fraction)
    }

    private static func candidatesSynchronously(in image: UIImage, geometry: InputGeometry) throws -> [Candidate] {
        guard let pixelBuffer = pixelBuffer(from: image, size: inputSize, imageRect: geometry.imageRect) else {
            throw DetectionError.imagePreparationFailed
        }
        guard let scoreMap = scoreMap(from: image) else {
            throw DetectionError.imagePreparationFailed
        }
        let sizeConstraints = sizeConstraints()

        let model = try loadModel()
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try model.prediction(from: input)

        guard let predictions = output.featureValue(for: predictionName)?.multiArrayValue,
              let prototypes = output.featureValue(for: prototypeName)?.multiArrayValue else {
            throw DetectionError.invalidModelOutput
        }

        return decodeCandidates(
            from: predictions,
            prototypes: prototypes,
            scoreMap: scoreMap,
            sizeConstraints: sizeConstraints
        )
    }

    private static func loadModel() throws -> MLModel {
        guard let url = Bundle.main.url(forResource: "FastSAM-s", withExtension: "mlmodelc") else {
            throw DetectionError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private static func inputGeometry(for image: UIImage, size: Int) -> InputGeometry {
        InputGeometry(imageRect: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private static func pixelBuffer(from image: UIImage, size: Int, imageRect: CGRect) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            size,
            size,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        UIGraphicsPushContext(context)
        image.draw(in: imageRect)
        UIGraphicsPopContext()
        return pixelBuffer
    }

    private static func scoreMap(from image: UIImage) -> ScoreMap? {
        let inputImageRect = inputGeometry(for: image, size: inputSize).imageRect
        let protoImageRect = CGRect(
            x: inputImageRect.minX / CGFloat(inputSize) * CGFloat(protoSize),
            y: inputImageRect.minY / CGFloat(inputSize) * CGFloat(protoSize),
            width: inputImageRect.width / CGFloat(inputSize) * CGFloat(protoSize),
            height: inputImageRect.height / CGFloat(inputSize) * CGFloat(protoSize)
        )
        guard let pixels = rgbaPixels(from: image, size: protoSize, imageRect: protoImageRect) else {
            return nil
        }

        let count = protoSize * protoSize
        var red = Array(repeating: Float(0), count: count)
        var green = Array(repeating: Float(0), count: count)
        var blue = Array(repeating: Float(0), count: count)
        var gray = Array(repeating: Float(0), count: count)
        var saturation = Array(repeating: Float(0), count: count)
        var value = Array(repeating: Float(0), count: count)
        var wallMask = Array(repeating: false, count: count)

        for index in 0..<count {
            let byteIndex = index * 4
            let r = Float(pixels[byteIndex]) / 255
            let g = Float(pixels[byteIndex + 1]) / 255
            let b = Float(pixels[byteIndex + 2]) / 255
            let maxChannel = max(r, max(g, b))
            let minChannel = min(r, min(g, b))
            let channelDelta = maxChannel - minChannel

            red[index] = r
            green[index] = g
            blue[index] = b
            gray[index] = (0.299 * r) + (0.587 * g) + (0.114 * b)
            saturation[index] = maxChannel > 0 ? channelDelta / maxChannel : 0
            value[index] = maxChannel
            wallMask[index] = maxChannel > 0.08
        }

        let redBlur = boxBlur(red, width: protoSize, height: protoSize, radius: 5)
        let greenBlur = boxBlur(green, width: protoSize, height: protoSize, radius: 5)
        let blueBlur = boxBlur(blue, width: protoSize, height: protoSize, radius: 5)
        let grayBlur = boxBlur(gray, width: protoSize, height: protoSize, radius: 4)

        var colorDelta = Array(repeating: Float(0), count: count)
        var brightnessDelta = Array(repeating: Float(0), count: count)
        var texture = Array(repeating: Float(0), count: count)
        var lowerBoost = Array(repeating: Float(0), count: count)

        for y in 0..<protoSize {
            let rowRatio = Float(y) / Float(max(1, protoSize - 1))
            let rowBoost = min(1, max(0, (rowRatio - 0.70) / 0.30))
            for x in 0..<protoSize {
                let index = (y * protoSize) + x
                let dr = red[index] - redBlur[index]
                let dg = green[index] - greenBlur[index]
                let db = blue[index] - blueBlur[index]
                colorDelta[index] = sqrt((dr * dr) + (dg * dg) + (db * db))
                brightnessDelta[index] = abs(gray[index] - grayBlur[index])
                lowerBoost[index] = rowBoost

                let left = gray[(y * protoSize) + max(0, x - 1)]
                let right = gray[(y * protoSize) + min(protoSize - 1, x + 1)]
                let up = gray[(max(0, y - 1) * protoSize) + x]
                let down = gray[(min(protoSize - 1, y + 1) * protoSize) + x]
                texture[index] = abs(right - left) + abs(down - up)
            }
        }

        colorDelta = normalized(colorDelta, mask: wallMask)
        brightnessDelta = normalized(brightnessDelta, mask: wallMask)
        texture = normalized(texture, mask: wallMask)
        saturation = normalized(saturation, mask: wallMask)
        value = normalized(value, mask: wallMask)

        var scores = Array(repeating: Float(0), count: count)
        var wallArea = 0
        for index in 0..<count where wallMask[index] {
            wallArea += 1
            scores[index] = (0.34 * colorDelta[index])
                + (0.20 * saturation[index])
                + (0.18 * brightnessDelta[index])
                + (0.17 * texture[index])
                + (0.06 * value[index])
                + (0.05 * lowerBoost[index])
        }

        return ScoreMap(scores: scores, wallMask: wallMask, wallArea: wallArea)
    }

    private static func rgbaPixels(from image: UIImage, size: Int, imageRect: CGRect) -> [UInt8]? {
        var pixels = Array(repeating: UInt8(0), count: size * size * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: size * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .high
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIGraphicsPushContext(context)
            image.draw(in: imageRect)
            UIGraphicsPopContext()
            return true
        }

        return didDraw ? pixels : nil
    }

    private static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else {
            return values
        }

        var horizontal = Array(repeating: Float(0), count: values.count)
        for y in 0..<height {
            var prefix = Array(repeating: Float(0), count: width + 1)
            for x in 0..<width {
                prefix[x + 1] = prefix[x] + values[(y * width) + x]
            }
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                let sum = prefix[x1 + 1] - prefix[x0]
                let span = x1 - x0 + 1
                horizontal[(y * width) + x] = sum / Float(span)
            }
        }

        var blurred = Array(repeating: Float(0), count: values.count)
        for x in 0..<width {
            var prefix = Array(repeating: Float(0), count: height + 1)
            for y in 0..<height {
                prefix[y + 1] = prefix[y] + horizontal[(y * width) + x]
            }
            for y in 0..<height {
                let y0 = max(0, y - radius)
                let y1 = min(height - 1, y + radius)
                let sum = prefix[y1 + 1] - prefix[y0]
                let span = y1 - y0 + 1
                blurred[(y * width) + x] = sum / Float(span)
            }
        }
        return blurred
    }

    private static func normalized(_ values: [Float], mask: [Bool]) -> [Float] {
        let masked = values.indices.compactMap { mask[$0] ? values[$0] : nil }.sorted()
        guard masked.count > 4 else {
            return values
        }

        let low = masked[Int(Double(masked.count - 1) * 0.02)]
        let high = masked[Int(Double(masked.count - 1) * 0.98)]
        let scale = max(high - low, 0.0001)
        return values.map { min(1, max(0, ($0 - low) / scale)) }
    }

    private static func decodeCandidates(
        from predictions: MLMultiArray,
        prototypes: MLMultiArray,
        scoreMap: ScoreMap,
        sizeConstraints: SizeConstraints
    ) -> [Candidate] {
        let channelCount = predictions.shape[1].intValue
        let candidateCount = predictions.shape[2].intValue
        guard channelCount >= 37 else {
            return []
        }

        let pointer = predictions.dataPointer.bindMemory(to: Float.self, capacity: predictions.count)
        let channelStride = predictions.strides[1].intValue
        let candidateStride = predictions.strides[2].intValue

        func value(channel: Int, candidate: Int) -> Float {
            pointer[(channel * channelStride) + (candidate * candidateStride)]
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(512)

        for index in 0..<candidateCount {
            let confidence = value(channel: 4, candidate: index)
            guard confidence >= 0.22 else {
                continue
            }

            let centerX = CGFloat(value(channel: 0, candidate: index))
            let centerY = CGFloat(value(channel: 1, candidate: index))
            let width = CGFloat(value(channel: 2, candidate: index))
            let height = CGFloat(value(channel: 3, candidate: index))
            guard width >= 6, height >= 6 else {
                continue
            }

            let rect = CGRect(
                x: max(0, centerX - (width / 2)),
                y: max(0, centerY - (height / 2)),
                width: min(CGFloat(inputSize), width),
                height: min(CGFloat(inputSize), height)
            ).intersection(CGRect(x: 0, y: 0, width: inputSize, height: inputSize))

            guard !rect.isNull, rect.width >= 6, rect.height >= 6 else {
                continue
            }

            let area = rect.width * rect.height
            let aspectRatio = max(rect.width, rect.height) / max(1, min(rect.width, rect.height))
            guard area <= CGFloat(inputSize * inputSize) / 5, aspectRatio <= 8 else {
                continue
            }

            let coefficients = (0..<32).map { value(channel: 5 + $0, candidate: index) }
            var candidate = Candidate(rect: rect, confidence: confidence, coefficients: coefficients)
            guard let mask = maskSummary(
                for: candidate,
                prototypes: prototypes,
                scoreMap: scoreMap,
                sizeConstraints: sizeConstraints
            ) else {
                continue
            }

            candidate.rect = mask.rect
            candidate.contour = mask.contour
            candidate.maskPixels = mask.maskPixels
            candidate.holdScore = mask.score
            candidates.append(candidate)
        }

        return candidates
            .sorted { $0.holdScore > $1.holdScore }
            .prefix(700)
            .map { $0 }
    }

    private static func selectCandidates(_ candidates: [Candidate], targetCount: Int) -> [Candidate] {
        let deduped = suppressDuplicates(candidates)
        guard targetCount > 0, deduped.count > targetCount else {
            return deduped.sorted { sortTopToBottom($0, $1) }
        }

        let bandEdges: [CGFloat] = [0.0, 0.20, 0.40, 0.60, 0.80, 1.01]
        let bandRatios: [CGFloat] = [0.10, 0.21, 0.29, 0.25, 0.15]
        var bandTargets = bandRatios.map { Int(round(CGFloat(targetCount) * $0)) }
        bandTargets[bandTargets.count - 1] += targetCount - bandTargets.reduce(0, +)

        var selected: [Candidate] = []
        for bandIndex in 0..<bandTargets.count {
            let y0 = bandEdges[bandIndex] * CGFloat(inputSize)
            let y1 = bandEdges[bandIndex + 1] * CGFloat(inputSize)
            let pool = deduped.filter { y0 <= $0.center.y && $0.center.y < y1 }

            var bandCount = 0
            for candidate in pool {
                guard !selected.contains(where: { detectionsOverlap(candidate, $0) }) else {
                    continue
                }
                selected.append(candidate)
                bandCount += 1
                if bandCount >= bandTargets[bandIndex] || selected.count >= targetCount {
                    break
                }
            }
        }

        if selected.count < targetCount {
            for candidate in deduped where !selected.contains(where: { detectionsOverlap(candidate, $0) }) {
                selected.append(candidate)
                if selected.count >= targetCount {
                    break
                }
            }
        }

        return selected
            .sorted { $0.holdScore > $1.holdScore }
            .prefix(targetCount)
            .sorted { sortTopToBottom($0, $1) }
    }

    private static func candidate(atDisplayPoint point: CGPoint, in candidates: [Candidate]) -> Candidate? {
        let modelPoint = CGPoint(
            x: point.x,
            y: CGFloat(inputSize) - point.y
        )
        let scale = CGFloat(inputSize) / CGFloat(protoSize)
        let protoX = min(max(0, Int(modelPoint.x / scale)), protoSize - 1)
        let protoY = min(max(0, Int(modelPoint.y / scale)), protoSize - 1)
        let hits = candidates.filter { candidate in
            maskContains(candidate, protoX: protoX, protoY: protoY)
        }
        return hits.max { lhs, rhs in
            let lhsDistance = hypot(modelPoint.x - lhs.center.x, modelPoint.y - lhs.center.y)
            let rhsDistance = hypot(modelPoint.x - rhs.center.x, modelPoint.y - rhs.center.y)
            if abs(lhsDistance - rhsDistance) > 0.001 {
                return lhsDistance > rhsDistance
            }
            return lhs.holdScore < rhs.holdScore
        }
    }

    private static func maskContains(_ candidate: Candidate, protoX: Int, protoY: Int) -> Bool {
        let radius = 2
        for y in max(0, protoY - radius)...min(protoSize - 1, protoY + radius) {
            for x in max(0, protoX - radius)...min(protoSize - 1, protoX + radius) {
                if candidate.maskPixels.contains((y * protoSize) + x) {
                    return true
                }
            }
        }
        return false
    }

    private static func suppressDuplicates(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.holdScore > $1.holdScore }) {
            guard !kept.contains(where: { detectionsOverlap(candidate, $0) }) else {
                continue
            }
            kept.append(candidate)
        }
        return kept
    }

    private static func detectionsOverlap(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let intersection = lhs.rect.intersection(rhs.rect)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return centersTooClose(lhs, rhs)
        }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.area + rhs.area - intersectionArea
        let containment = intersectionArea / max(1, min(lhs.area, rhs.area))
        let iou = intersectionArea / max(1, unionArea)
        return iou > 0.18 || containment > 0.62 || centersTooClose(lhs, rhs)
    }

    private static func centersTooClose(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let dx = lhs.center.x - rhs.center.x
        let dy = lhs.center.y - rhs.center.y
        let distance = sqrt((dx * dx) + (dy * dy))
        let sizeLimit = 0.38 * min(max(lhs.rect.width, lhs.rect.height), max(rhs.rect.width, rhs.rect.height))
        return distance < sizeLimit
    }

    private static func hold(from candidate: Candidate, geometry: InputGeometry) -> Hold? {
        guard let rect = geometry.normalizedRect(fromModelRect: candidate.rect) else {
            return nil
        }

        return Hold(
            rect: rect,
            contour: nil,
            confidence: Double(candidate.holdScore)
        )
    }

    private static func maskSummary(
        for candidate: Candidate,
        prototypes: MLMultiArray,
        scoreMap: ScoreMap,
        sizeConstraints: SizeConstraints
    ) -> (rect: CGRect, contour: [NormalizedPoint]?, maskPixels: Set<Int>, score: Float)? {
        let pointer = prototypes.dataPointer.bindMemory(to: Float.self, capacity: prototypes.count)
        let channelStride = prototypes.strides[1].intValue
        let yStride = prototypes.strides[2].intValue
        let xStride = prototypes.strides[3].intValue
        let scale = CGFloat(inputSize) / CGFloat(protoSize)

        let px0 = max(0, Int(floor(candidate.rect.minX / scale)) - 1)
        let px1 = min(protoSize - 1, Int(ceil(candidate.rect.maxX / scale)) + 1)
        let py0 = max(0, Int(floor(candidate.rect.minY / scale)) - 1)
        let py1 = min(protoSize - 1, Int(ceil(candidate.rect.maxY / scale)) + 1)
        guard px0 <= px1, py0 <= py1 else {
            return nil
        }

        let width = px1 - px0 + 1
        let height = py1 - py0 + 1
        var mask = Array(repeating: false, count: width * height)
        var rawCount = 0

        func prototypeValue(channel: Int, x: Int, y: Int) -> Float {
            pointer[(channel * channelStride) + (y * yStride) + (x * xStride)]
        }

        for y in py0...py1 {
            for x in px0...px1 {
                var value: Float = 0
                for channel in 0..<32 {
                    value += candidate.coefficients[channel] * prototypeValue(channel: channel, x: x, y: y)
                }

                guard sigmoid(value) >= 0.5 else {
                    continue
                }
                rawCount += 1
                guard scoreMap.isWall(x: x, y: y) else {
                    continue
                }

                let localIndex = ((y - py0) * width) + (x - px0)
                mask[localIndex] = true
            }
        }

        guard let component = largestComponent(in: mask, width: width, height: height, offsetX: px0, offsetY: py0) else {
            return nil
        }
        let count = component.indices.count

        let insideRatio = Float(count) / Float(max(rawCount, 1))
        guard insideRatio >= 0.70 else {
            return nil
        }

        let rect = CGRect(
            x: CGFloat(component.minX) * scale,
            y: CGFloat(component.minY) * scale,
            width: CGFloat(component.maxX - component.minX + 1) * scale,
            height: CGFloat(component.maxY - component.minY + 1) * scale
        )

        let bboxArea = max(1, (component.maxX - component.minX + 1) * (component.maxY - component.minY + 1))
        let fillRatio = Float(count) / Float(bboxArea)
        let aspectRatio = Float(max(rect.width, rect.height) / max(1, min(rect.width, rect.height)))
        let areaPixels = CGFloat(count) * scale * scale
        let perimeterPixels = CGFloat(boundaryCount(for: component, localWidth: width, localHeight: height)) * scale
        let minDimension = min(rect.width, rect.height)
        let maxDimension = max(rect.width, rect.height)
        let minArea = max(14, scoreMap.wallArea / 30000)
        let maxArea = max(minArea + 1, scoreMap.wallArea / 5)
        guard count >= minArea, count <= maxArea, minDimension >= 3 else {
            return nil
        }
        guard areaPixels >= sizeConstraints.minArea,
              areaPixels <= sizeConstraints.maxArea,
              perimeterPixels >= sizeConstraints.minPerimeter,
              perimeterPixels <= sizeConstraints.maxPerimeter,
              minDimension >= sizeConstraints.minMinDimension,
              maxDimension >= sizeConstraints.minMaxDimension,
              maxDimension <= sizeConstraints.maxDimension else {
            return nil
        }
        guard fillRatio >= 0.055 else {
            return nil
        }
        guard aspectRatio <= 8.0 || fillRatio >= 0.22 else {
            return nil
        }

        var scoreSum: Float = 0
        var peakScore: Float = 0
        for localIndex in component.indices {
            let x = (localIndex % width) + px0
            let y = (localIndex / width) + py0
            let localScore = scoreMap.score(x: x, y: y)
            scoreSum += localScore
            peakScore = max(peakScore, localScore)
        }
        guard peakScore >= 0.10 else {
            return nil
        }

        let meanScore = scoreSum / Float(max(count, 1))
        let sizeScore = min(1, sqrt(Float(count)) / 22)
        let score = (0.34 * candidate.confidence)
            + (0.28 * peakScore)
            + (0.18 * meanScore)
            + (0.10 * min(1, fillRatio))
            + (0.10 * sizeScore)
        let contour = contourPoints(
            for: component,
            localWidth: width,
            localHeight: height,
            offsetX: px0,
            offsetY: py0
        )
        let maskPixels = Set(component.indices.map { localIndex in
            let x = (localIndex % width) + px0
            let y = (localIndex / width) + py0
            return (y * protoSize) + x
        })
        return (rect, contour.count >= 3 ? contour : nil, maskPixels, score)
    }

    private static func sizeConstraints() -> SizeConstraints {
        let referenceWidth: CGFloat = 3019
        let referenceHeight: CGFloat = 5690
        let xScale = CGFloat(inputSize) / referenceWidth
        let yScale = CGFloat(inputSize) / referenceHeight
        let areaScale = xScale * yScale
        let minLinearScale = min(xScale, yScale)
        let maxLinearScale = max(xScale, yScale)

        return SizeConstraints(
            minArea: 1783.9891357421875 * areaScale,
            minPerimeter: 144.5114288330078 * minLinearScale,
            minMinDimension: 45.0 * minLinearScale,
            minMaxDimension: 48.0 * minLinearScale,
            maxArea: 146212.7783203125 * areaScale,
            maxPerimeter: 1268.0570068359375 * maxLinearScale,
            maxDimension: 487.5 * maxLinearScale
        )
    }

    private static func largestComponent(
        in mask: [Bool],
        width: Int,
        height: Int,
        offsetX: Int,
        offsetY: Int
    ) -> MaskComponent? {
        var visited = Array(repeating: false, count: mask.count)
        var best: MaskComponent?
        let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for start in mask.indices where mask[start] && !visited[start] {
            var stack = [start]
            var indices: [Int] = []
            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0
            visited[start] = true

            while let current = stack.popLast() {
                indices.append(current)
                let x = current % width
                let y = current / width
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                for (dx, dy) in neighbors {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else {
                        continue
                    }
                    let next = (ny * width) + nx
                    guard mask[next], !visited[next] else {
                        continue
                    }
                    visited[next] = true
                    stack.append(next)
                }
            }

            let component = MaskComponent(
                indices: indices,
                minX: minX + offsetX,
                minY: minY + offsetY,
                maxX: maxX + offsetX,
                maxY: maxY + offsetY
            )
            if best == nil || component.indices.count > best!.indices.count {
                best = component
            }
        }

        return best
    }

    private static func boundaryCount(for component: MaskComponent, localWidth: Int, localHeight: Int) -> Int {
        let componentSet = Set(component.indices)
        var count = 0

        for localIndex in component.indices {
            let x = localIndex % localWidth
            let y = localIndex / localWidth
            let isBoundary = x == 0 || y == 0 || x == localWidth - 1 || y == localHeight - 1
                || !componentSet.contains(localIndex - 1)
                || !componentSet.contains(localIndex + 1)
                || !componentSet.contains(localIndex - localWidth)
                || !componentSet.contains(localIndex + localWidth)
            if isBoundary {
                count += 1
            }
        }

        return count
    }

    private static func contourPoints(
        for component: MaskComponent,
        localWidth: Int,
        localHeight: Int,
        offsetX: Int,
        offsetY: Int
    ) -> [NormalizedPoint] {
        let componentSet = Set(component.indices)
        var boundary: [(x: Int, y: Int)] = []
        boundary.reserveCapacity(component.indices.count)

        for localIndex in component.indices {
            let x = localIndex % localWidth
            let y = localIndex / localWidth
            let isBoundary = x == 0 || y == 0 || x == localWidth - 1 || y == localHeight - 1
                || !componentSet.contains(localIndex - 1)
                || !componentSet.contains(localIndex + 1)
                || !componentSet.contains(localIndex - localWidth)
                || !componentSet.contains(localIndex + localWidth)
            guard isBoundary else {
                continue
            }
            boundary.append((x: x + offsetX, y: y + offsetY))
        }

        guard boundary.count >= 3 else {
            return []
        }

        let centerX = CGFloat(component.minX + component.maxX) / 2
        let centerY = CGFloat(component.minY + component.maxY) / 2
        let ordered = boundary.sorted { lhs, rhs in
            atan2(CGFloat(lhs.y) - centerY, CGFloat(lhs.x) - centerX)
                < atan2(CGFloat(rhs.y) - centerY, CGFloat(rhs.x) - centerX)
        }
        let decimated = decimated(ordered, maxCount: 96)
        return decimated.map { point in
            NormalizedPoint(
                x: (CGFloat(point.x) + 0.5) / CGFloat(protoSize),
                y: (CGFloat(point.y) + 0.5) / CGFloat(protoSize)
            ).clamped()
        }
    }

    private static func decimated<T>(_ items: [T], maxCount: Int) -> [T] {
        guard items.count > maxCount, maxCount > 2 else {
            return items
        }
        let step = Double(items.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { items[min(items.count - 1, Int(round(Double($0) * step)))] }
    }

    private static func sigmoid(_ value: Float) -> Float {
        1 / (1 + exp(-value))
    }

    private static func sortTopToBottom(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if abs(lhs.rect.minY - rhs.rect.minY) > 8 {
            return lhs.rect.minY < rhs.rect.minY
        }
        return lhs.rect.minX < rhs.rect.minX
    }
}
