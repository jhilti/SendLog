import Foundation
import UIKit

@MainActor
final class AppStore: ObservableObject {
    enum AppStoreError: LocalizedError {
        case invalidImage
        case wallNotFound
        case missingWallImage
        case invalidBackupData
        case unsupportedBackupVersion

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "The selected image data is invalid."
            case .wallNotFound:
                return "Could not find this wall."
            case .missingWallImage:
                return "The wall image is missing from local storage."
            case .invalidBackupData:
                return "The backup file is corrupted or unsupported."
            case .unsupportedBackupVersion:
                return "This backup version is not supported by the current app."
            }
        }
    }

    private struct BackupPayload: Codable {
        static let currentVersion = 1

        let version: Int
        let exportedAt: Date
        let walls: [BackupWall]
    }

    private struct BackupWall: Codable {
        let wall: Wall
        let imageDataBase64: String
    }

    @Published private(set) var walls: [Wall] = []
    @Published private(set) var hasLoaded = false

    private let repository: WallRepository
    private let imageStore: ImageStore
    private let detector: HoldDetectionService
    private let imageCache = NSCache<NSString, UIImage>()

    init(
        repository: WallRepository = WallRepository(),
        imageStore: ImageStore = ImageStore(),
        detector: HoldDetectionService = HoldDetectionService()
    ) {
        self.repository = repository
        self.imageStore = imageStore
        self.detector = detector

        Task {
            await load()
        }
    }

    func load() async {
        do {
            let loadedWalls = try await repository.loadWalls()
            walls = loadedWalls.sorted { $0.updatedAt > $1.updatedAt }
            hasLoaded = true
        } catch {
            walls = []
            hasLoaded = true
        }
    }

    func wall(withID id: UUID) -> Wall? {
        walls.first { $0.id == id }
    }

    func image(for wall: Wall) -> UIImage? {
        let cacheKey = wall.imageFilename as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        guard let image = imageStore.loadImage(filename: wall.imageFilename) else {
            return nil
        }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    func createWall(name: String, imageData: Data) async throws {
        guard UIImage(data: imageData) != nil else {
            throw AppStoreError.invalidImage
        }

        let wallID = UUID()
        let filename = try imageStore.saveImageData(imageData, for: wallID)
        let newWall = Wall(
            id: wallID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            imageFilename: filename
        )

        walls.insert(newWall, at: 0)
        try await persist()
    }

    func detectHolds(for wallID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let image = image(for: walls[index]) else {
            throw AppStoreError.missingWallImage
        }

        let detected = try await detector.detectHolds(in: image)
        walls[index].holds = detected
        walls[index].updatedAt = Date()
        try await persist()
    }

    func removeHold(wallID: UUID, holdID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        walls[index].holds.removeAll { $0.id == holdID }
        walls[index].updatedAt = Date()
        try await persist()
    }

    func addManualHold(wallID: UUID, at normalizedPoint: CGPoint) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }

        let defaultSize: CGFloat = 0.08
        let rect = NormalizedRect(
            x: normalizedPoint.x - (defaultSize / 2),
            y: normalizedPoint.y - (defaultSize / 2),
            width: defaultSize,
            height: defaultSize
        ).clamped()

        let newHold = Hold(rect: rect, confidence: 1.0, source: .manual)
        walls[index].holds.append(newHold)
        walls[index].updatedAt = Date()
        try await persist()
    }

    func saveBoulder(
        wallID: UUID,
        name: String,
        grade: String,
        notes: String,
        holdIDs: [UUID]
    ) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }

        let boulder = Boulder(
            wallID: wallID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            grade: grade.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            holdIDs: holdIDs
        )

        walls[index].boulders.insert(boulder, at: 0)
        walls[index].updatedAt = Date()
        try await persist()
    }

    func deleteBoulder(wallID: UUID, boulderID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }

        walls[index].boulders.removeAll { $0.id == boulderID }
        walls[index].updatedAt = Date()
        try await persist()
    }

    func exportBackupData() throws -> Data {
        let backupWalls = try walls.map { wall -> BackupWall in
            guard let imageData = imageStore.loadImageData(filename: wall.imageFilename) else {
                throw AppStoreError.missingWallImage
            }
            return BackupWall(wall: wall, imageDataBase64: imageData.base64EncodedString())
        }

        let payload = BackupPayload(
            version: BackupPayload.currentVersion,
            exportedAt: Date(),
            walls: backupWalls
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    func importBackupData(_ data: Data) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: BackupPayload
        do {
            payload = try decoder.decode(BackupPayload.self, from: data)
        } catch {
            throw AppStoreError.invalidBackupData
        }

        guard payload.version == BackupPayload.currentVersion else {
            throw AppStoreError.unsupportedBackupVersion
        }

        var importedWalls: [Wall] = []
        importedWalls.reserveCapacity(payload.walls.count)

        for backupWall in payload.walls {
            guard let imageData = Data(base64Encoded: backupWall.imageDataBase64),
                  UIImage(data: imageData) != nil else {
                throw AppStoreError.invalidBackupData
            }

            var wall = backupWall.wall
            wall.imageFilename = try imageStore.saveImageData(imageData, for: wall.id)
            importedWalls.append(wall)
        }

        imageCache.removeAllObjects()
        walls = importedWalls.sorted { $0.updatedAt > $1.updatedAt }
        try await persist()
    }

    private func wallIndex(for wallID: UUID) -> Int? {
        walls.firstIndex { $0.id == wallID }
    }

    private func persist() async throws {
        walls.sort { $0.updatedAt > $1.updatedAt }
        try await repository.saveWalls(walls)
    }
}
