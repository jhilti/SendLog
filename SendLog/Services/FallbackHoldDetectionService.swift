import CoreGraphics
import UIKit

struct FallbackHoldDetectionService: HoldDetecting {
    let primary: (any HoldDetecting)?
    let fallback: any HoldDetecting

    init(primary: (any HoldDetecting)?, fallback: any HoldDetecting) {
        self.primary = primary
        self.fallback = fallback
    }

    func detectHolds(in image: UIImage) async throws -> [Hold] {
        if let primary {
            do {
                return try await primary.detectHolds(in: image)
            } catch {
                if shouldRetryRemote(error) {
                    do {
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        return try await primary.detectHolds(in: image)
                    } catch {
                        print("Remote hold detection failed after retry, falling back to on-device detection: \(error.localizedDescription)")
                    }
                } else {
                    print("Remote hold detection failed, falling back to on-device detection: \(error.localizedDescription)")
                }
            }
        }

        return try await fallback.detectHolds(in: image)
    }

    func segmentHold(around normalizedPoint: CGPoint, in image: UIImage) async throws -> Hold? {
        if let primary {
            do {
                if let hold = try await primary.segmentHold(around: normalizedPoint, in: image) {
                    return hold
                }
            } catch {
                if shouldRetryRemote(error) {
                    do {
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        if let hold = try await primary.segmentHold(around: normalizedPoint, in: image) {
                            return hold
                        }
                    } catch {
                        print("Remote hold segmentation failed after retry, falling back to on-device detection: \(error.localizedDescription)")
                    }
                } else {
                    print("Remote hold segmentation failed, falling back to on-device detection: \(error.localizedDescription)")
                }
            }
        }

        return try await fallback.segmentHold(around: normalizedPoint, in: image)
    }

    private func shouldRetryRemote(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && (nsError.code == NSURLErrorNotConnectedToInternet
                || nsError.code == NSURLErrorNetworkConnectionLost
                || nsError.code == NSURLErrorCannotConnectToHost
                || nsError.code == NSURLErrorTimedOut)
    }
}
