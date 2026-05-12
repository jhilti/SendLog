import CoreGraphics
import CoreML
import UIKit

struct OfflineHoldDetectionService {
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
        var confidence: Float
        var coefficients: [Float]

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

    func detectHolds(in image: UIImage, targetCount: Int = 92) async throws -> [Hold] {
        try await Task.detached(priority: .userInitiated) {
            try Self.detectHoldsSynchronously(in: image, targetCount: targetCount)
        }.value
    }

    private static func detectHoldsSynchronously(in image: UIImage, targetCount: Int) throws -> [Hold] {
        guard let pixelBuffer = pixelBuffer(from: image, size: inputSize) else {
            throw DetectionError.imagePreparationFailed
        }

        let model = try loadModel()
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try model.prediction(from: input)

        guard let predictions = output.featureValue(for: predictionName)?.multiArrayValue,
              let prototypes = output.featureValue(for: prototypeName)?.multiArrayValue else {
            throw DetectionError.invalidModelOutput
        }

        let candidates = decodeCandidates(from: predictions)
        let selected = selectCandidates(candidates, targetCount: targetCount)
        return selected.map { candidate in
            hold(from: candidate, prototypes: prototypes)
        }
    }

    private static func loadModel() throws -> MLModel {
        guard let url = Bundle.main.url(forResource: "FastSAM-s", withExtension: "mlmodelc") else {
            throw DetectionError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    private static func pixelBuffer(from image: UIImage, size: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            size,
            size,
            kCVPixelFormatType_32ARGB,
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
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        UIGraphicsPopContext()
        return pixelBuffer
    }

    private static func decodeCandidates(from predictions: MLMultiArray) -> [Candidate] {
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
            candidates.append(Candidate(rect: rect, confidence: confidence, coefficients: coefficients))
        }

        return candidates
            .sorted { $0.confidence > $1.confidence }
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
            .sorted { $0.confidence > $1.confidence }
            .prefix(targetCount)
            .sorted { sortTopToBottom($0, $1) }
    }

    private static func suppressDuplicates(_ candidates: [Candidate]) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
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

    private static func hold(from candidate: Candidate, prototypes: MLMultiArray) -> Hold {
        let mask = maskSummary(for: candidate, prototypes: prototypes)
        let rect = mask?.rect ?? candidate.rect
        let contour = mask?.contour

        return Hold(
            rect: NormalizedRect(
                x: rect.minX / CGFloat(inputSize),
                y: rect.minY / CGFloat(inputSize),
                width: rect.width / CGFloat(inputSize),
                height: rect.height / CGFloat(inputSize)
            ).clamped(),
            contour: contour,
            confidence: Double(candidate.confidence)
        )
    }

    private static func maskSummary(
        for candidate: Candidate,
        prototypes: MLMultiArray
    ) -> (rect: CGRect, contour: [NormalizedPoint]?)? {
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
        var minX = protoSize
        var minY = protoSize
        var maxX = 0
        var maxY = 0
        var count = 0

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

                let localIndex = (y - py0) * width + (x - px0)
                mask[localIndex] = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                count += 1
            }
        }

        guard count >= 4, minX <= maxX, minY <= maxY else {
            return nil
        }

        let rect = CGRect(
            x: CGFloat(minX) * scale,
            y: CGFloat(minY) * scale,
            width: CGFloat(maxX - minX + 1) * scale,
            height: CGFloat(maxY - minY + 1) * scale
        )

        var boundary: [NormalizedPoint] = []
        for y in py0...py1 {
            for x in px0...px1 {
                let lx = x - px0
                let ly = y - py0
                let localIndex = ly * width + lx
                guard mask[localIndex] else {
                    continue
                }

                let isBoundary = lx == 0 || ly == 0 || lx == width - 1 || ly == height - 1
                    || !mask[localIndex - 1]
                    || !mask[localIndex + 1]
                    || !mask[localIndex - width]
                    || !mask[localIndex + width]
                guard isBoundary else {
                    continue
                }

                boundary.append(NormalizedPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(protoSize),
                    y: (CGFloat(y) + 0.5) / CGFloat(protoSize)
                ).clamped())
            }
        }

        let contour = decimated(boundary, maxCount: 80)
        return (rect, contour.count >= 3 ? contour : nil)
    }

    private static func decimated(_ points: [NormalizedPoint], maxCount: Int) -> [NormalizedPoint] {
        guard points.count > maxCount, maxCount > 2 else {
            return points
        }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { points[min(points.count - 1, Int(round(Double($0) * step)))] }
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
