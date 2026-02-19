import Foundation
import UIKit

struct ImageStore {
    private let fileManager = FileManager.default
    private let rootFolder = "SendLog"
    private let imageFolder = "WallImages"

    func saveImageData(_ data: Data, for wallID: UUID) throws -> String {
        let directoryURL = try imageDirectoryURL()
        let filename = "wall-\(wallID.uuidString).jpg"
        let fileURL = directoryURL.appendingPathComponent(filename)
        try data.write(to: fileURL, options: [.atomic])
        return filename
    }

    func loadImage(filename: String) -> UIImage? {
        let fileURL = imageDirectoryURLWithoutCreation().appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return UIImage(data: data)
    }

    func loadImageData(filename: String) -> Data? {
        let fileURL = imageDirectoryURLWithoutCreation().appendingPathComponent(filename)
        return try? Data(contentsOf: fileURL)
    }

    private func imageDirectoryURL() throws -> URL {
        let appSupport = try appSupportDirectoryURL()
        let rootURL = appSupport.appendingPathComponent(rootFolder, isDirectory: true)
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        let imageURL = rootURL.appendingPathComponent(imageFolder, isDirectory: true)
        if !fileManager.fileExists(atPath: imageURL.path) {
            try fileManager.createDirectory(at: imageURL, withIntermediateDirectories: true)
        }
        return imageURL
    }

    private func imageDirectoryURLWithoutCreation() -> URL {
        let appSupport = (try? appSupportDirectoryURL()) ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent(rootFolder, isDirectory: true)
            .appendingPathComponent(imageFolder, isDirectory: true)
    }

    private func appSupportDirectoryURL() throws -> URL {
        guard let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "ImageStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing application support directory."])
        }
        return url
    }
}
