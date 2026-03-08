import Foundation

enum AppConfiguration {
    private static let remoteHoldDetectionURLKey = "SENDLOG_HOLD_DETECTION_URL"

    static var remoteHoldDetectionURL: URL? {
        if let envValue = ProcessInfo.processInfo.environment[remoteHoldDetectionURLKey],
           let url = parsedURL(from: envValue) {
            return url
        }

        if let plistValue = Bundle.main.object(forInfoDictionaryKey: remoteHoldDetectionURLKey) as? String,
           let url = parsedURL(from: plistValue) {
            return url
        }

        return nil
    }

    private static func parsedURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return URL(string: trimmed)
    }
}
