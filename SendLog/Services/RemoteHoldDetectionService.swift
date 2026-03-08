import Foundation
import UIKit

enum RemoteHoldDetectionError: LocalizedError {
    case imageEncodingFailed
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Could not prepare image for remote hold detection."
        case .invalidResponse:
            return "Remote hold detection returned an invalid response."
        case .serverError(let statusCode, let message):
            return "Remote hold detection failed (\(statusCode)): \(message)"
        }
    }
}

struct RemoteHoldDetectionService: HoldDetecting {
    private let endpointURL: URL
    private let session: URLSession
    private let timeout: TimeInterval
    private let jpegCompressionQuality: CGFloat

    init(
        endpointURL: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 45,
        jpegCompressionQuality: CGFloat = 0.9
    ) {
        self.endpointURL = endpointURL
        self.session = session
        self.timeout = timeout
        self.jpegCompressionQuality = jpegCompressionQuality
    }

    func detectHolds(in image: UIImage) async throws -> [Hold] {
        let payload = try requestPayload(from: image)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteHoldDetectionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteHoldDetectionError.serverError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(DetectionResponse.self, from: data)
        let holds = decoded.holds.compactMap { $0.asHold(source: .detected) }

        if holds.isEmpty {
            throw HoldDetectionError.noContours
        }

        return holds
    }

    func segmentHold(around normalizedPoint: CGPoint, in image: UIImage) async throws -> Hold? {
        let point = CGPoint(
            x: min(max(0, normalizedPoint.x), 1),
            y: min(max(0, normalizedPoint.y), 1)
        )
        let payload = try segmentationPayload(from: image, point: point)

        var request = URLRequest(url: segmentEndpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteHoldDetectionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RemoteHoldDetectionError.serverError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(SegmentationResponse.self, from: data)
        return decoded.hold?.asHold(source: .manual)
    }

    private func requestPayload(from image: UIImage) throws -> DetectionRequest {
        guard let data = image.jpegData(compressionQuality: jpegCompressionQuality) else {
            throw RemoteHoldDetectionError.imageEncodingFailed
        }

        return DetectionRequest(
            imageBase64: data.base64EncodedString(),
            imageWidth: Int(image.size.width),
            imageHeight: Int(image.size.height)
        )
    }

    private func segmentationPayload(from image: UIImage, point: CGPoint) throws -> SegmentationRequest {
        let detection = try requestPayload(from: image)
        return SegmentationRequest(
            imageBase64: detection.imageBase64,
            imageWidth: detection.imageWidth,
            imageHeight: detection.imageHeight,
            point: SegmentationPoint(x: point.x, y: point.y)
        )
    }

    private var segmentEndpointURL: URL {
        if endpointURL.lastPathComponent == "segment-hold" {
            return endpointURL
        }
        if endpointURL.lastPathComponent == "detect-holds" {
            return endpointURL
                .deletingLastPathComponent()
                .appendingPathComponent("segment-hold")
        }
        return endpointURL.appendingPathComponent("segment-hold")
    }
}

private struct DetectionRequest: Codable {
    let imageBase64: String
    let imageWidth: Int
    let imageHeight: Int

    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
    }
}

private struct DetectionResponse: Codable {
    let holds: [DetectionHold]
}

private struct SegmentationRequest: Codable {
    let imageBase64: String
    let imageWidth: Int
    let imageHeight: Int
    let point: SegmentationPoint

    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case point
    }
}

private struct SegmentationResponse: Codable {
    let hold: DetectionHold?
}

private struct SegmentationPoint: Codable {
    let x: CGFloat
    let y: CGFloat
}

private struct DetectionHold: Codable {
    let rect: DetectionRect
    let contour: [DetectionPoint]?
    let confidence: Double?

    func asHold(source: HoldSource) -> Hold? {
        let normalizedRect = NormalizedRect(
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        ).clamped()

        if normalizedRect.width <= 0 || normalizedRect.height <= 0 {
            return nil
        }

        let normalizedContour: [NormalizedPoint]?
        if let contour, contour.count >= 3 {
            normalizedContour = contour.map { point in
                NormalizedPoint(x: point.x, y: point.y).clamped()
            }
        } else {
            normalizedContour = nil
        }

        return Hold(
            rect: normalizedRect,
            contour: normalizedContour,
            confidence: min(1, max(0, confidence ?? 0.8)),
            source: source
        )
    }
}

private struct DetectionRect: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

private struct DetectionPoint: Codable {
    let x: CGFloat
    let y: CGFloat
}
