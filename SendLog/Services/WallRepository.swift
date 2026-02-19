import Foundation

actor WallRepository {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = appSupport.appendingPathComponent("SendLog", isDirectory: true)
        self.fileURL = root.appendingPathComponent("walls.json")
    }

    func loadWalls() throws -> [Wall] {
        let root = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Wall].self, from: data)
    }

    func saveWalls(_ walls: [Wall]) throws {
        let root = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(walls)
        try data.write(to: fileURL, options: [.atomic])
    }
}
