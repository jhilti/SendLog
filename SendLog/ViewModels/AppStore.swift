import Foundation
import CoreImage
import UIKit

@MainActor
final class AppStore: ObservableObject {
    enum AppStoreError: LocalizedError {
        case invalidImage
        case wallNotFound
        case boulderNotFound
        case missingWallImage
        case invalidBackupData
        case unsupportedBackupVersion

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "The selected image data is invalid."
            case .wallNotFound:
                return "Could not find this wall."
            case .boulderNotFound:
                return "Could not find this problem."
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
        let maskDataBase64: String?
    }

    @Published private(set) var walls: [Wall] = []
    @Published private(set) var hasLoaded = false

    private let repository: WallRepository
    private let imageStore: ImageStore
    private let detector: any HoldDetecting
    private let imageCache = NSCache<NSString, UIImage>()
    private let maskCache = NSCache<NSString, UIImage>()
    private let ciContext = CIContext(options: nil)

    init(
        repository: WallRepository = WallRepository(),
        imageStore: ImageStore = ImageStore(),
        detector: any HoldDetecting = HoldDetectionService()
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

    func mask(for wall: Wall) -> UIImage? {
        guard let maskFilename = wall.maskFilename, !maskFilename.isEmpty else {
            return nil
        }

        let cacheKey = maskFilename as NSString
        if let cached = maskCache.object(forKey: cacheKey) {
            return cached
        }

        guard let maskImage = imageStore.loadImage(filename: maskFilename) else {
            return nil
        }
        maskCache.setObject(maskImage, forKey: cacheKey)
        return maskImage
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

    func deleteWall(wallID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }

        let removedWall = walls.remove(at: index)

        do {
            try await persist()
        } catch {
            walls.insert(removedWall, at: index)
            throw error
        }

        imageCache.removeObject(forKey: removedWall.imageFilename as NSString)
        imageStore.deleteImage(filename: removedWall.imageFilename)

        if let maskFilename = removedWall.maskFilename {
            maskCache.removeObject(forKey: maskFilename as NSString)
            imageStore.deleteImage(filename: maskFilename)
        }
    }

    func setWallMask(wallID: UUID, imageData: Data) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard UIImage(data: imageData) != nil else {
            throw AppStoreError.invalidImage
        }

        if let currentMaskFilename = walls[index].maskFilename {
            imageStore.deleteImage(filename: currentMaskFilename)
            maskCache.removeObject(forKey: currentMaskFilename as NSString)
        }

        let filename = try imageStore.saveMaskImageData(imageData, for: wallID)
        walls[index].maskFilename = filename
        walls[index].updatedAt = Date()
        try await persist()
    }

    func clearWallMask(wallID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let currentMaskFilename = walls[index].maskFilename else {
            return
        }

        imageStore.deleteImage(filename: currentMaskFilename)
        maskCache.removeObject(forKey: currentMaskFilename as NSString)
        walls[index].maskFilename = nil
        walls[index].updatedAt = Date()
        try await persist()
    }

    func detectHolds(for wallID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let detectionImage = detectionImage(for: walls[index]) else {
            throw AppStoreError.missingWallImage
        }

        let detected = try await detector.detectHolds(in: detectionImage)
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

    func removeAllHolds(wallID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        walls[index].holds = []
        walls[index].updatedAt = Date()
        try await persist()
    }

    func removeLastManualHold(wallID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let lastIndex = walls[index].holds.lastIndex(where: { $0.source == .manual }) else {
            return
        }
        walls[index].holds.remove(at: lastIndex)
        walls[index].updatedAt = Date()
        try await persist()
    }

    func addManualHold(wallID: UUID, at normalizedPoint: CGPoint) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let detectionImage = detectionImage(for: walls[index]) else {
            throw AppStoreError.missingWallImage
        }

        let point = CGPoint(
            x: min(max(0, normalizedPoint.x), 1),
            y: min(max(0, normalizedPoint.y), 1)
        )

        var newHold = try await detector.segmentHold(around: point, in: detectionImage)
            ?? manualRingMarker(at: point)
        newHold.source = .manual
        walls[index].holds.append(newHold)
        walls[index].updatedAt = Date()
        try await persist()
    }

    @discardableResult
    func addManualMarkerHold(wallID: UUID, at normalizedPoint: CGPoint) async throws -> UUID {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }

        let point = CGPoint(
            x: min(max(0, normalizedPoint.x), 1),
            y: min(max(0, normalizedPoint.y), 1)
        )

        let newHold = manualRingMarker(at: point)
        walls[index].holds.append(newHold)
        walls[index].updatedAt = Date()
        try await persist()
        return newHold.id
    }

    func moveHold(wallID: UUID, holdID: UUID, to normalizedPoint: CGPoint) async throws {
        guard let wallIndex = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let holdIndex = walls[wallIndex].holds.firstIndex(where: { $0.id == holdID }) else {
            return
        }

        let clampedPoint = CGPoint(
            x: min(max(0, normalizedPoint.x), 1),
            y: min(max(0, normalizedPoint.y), 1)
        )
        walls[wallIndex].holds[holdIndex] = movedHold(walls[wallIndex].holds[holdIndex], to: clampedPoint)
        walls[wallIndex].updatedAt = Date()
        try await persist()
    }

    func addManualHoldContour(wallID: UUID, points normalizedPoints: [CGPoint]) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }

        let cleaned = normalizedPoints
            .map { point in
                CGPoint(x: min(max(0, point.x), 1), y: min(max(0, point.y), 1))
            }
        guard cleaned.count >= 3 else {
            return
        }

        let decimated = decimatedContour(cleaned, maxCount: 120)
        let contour = decimated.map { point in
            NormalizedPoint(x: point.x, y: point.y)
        }

        let minX = contour.map(\.x).min() ?? 0
        let maxX = contour.map(\.x).max() ?? 1
        let minY = contour.map(\.y).min() ?? 0
        let maxY = contour.map(\.y).max() ?? 1

        let rect = NormalizedRect(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY)
        ).clamped()

        let hold = Hold(
            rect: rect,
            contour: contour,
            confidence: 0.85,
            source: .manual
        )

        walls[index].holds.append(hold)
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

    func updateBoulder(
        wallID: UUID,
        boulderID: UUID,
        name: String,
        grade: String,
        notes: String,
        holdIDs: [UUID]
    ) async throws {
        guard let wallIdx = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let boulderIdx = walls[wallIdx].boulders.firstIndex(where: { $0.id == boulderID }) else {
            throw AppStoreError.boulderNotFound
        }

        walls[wallIdx].boulders[boulderIdx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        walls[wallIdx].boulders[boulderIdx].grade = grade.trimmingCharacters(in: .whitespacesAndNewlines)
        walls[wallIdx].boulders[boulderIdx].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        walls[wallIdx].boulders[boulderIdx].holdIDs = holdIDs
        walls[wallIdx].updatedAt = Date()
        try await persist()
    }

    func incrementBoulderTick(wallID: UUID, boulderID: UUID) async throws {
        guard let wallIdx = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let boulderIdx = walls[wallIdx].boulders.firstIndex(where: { $0.id == boulderID }) else {
            throw AppStoreError.boulderNotFound
        }

        walls[wallIdx].boulders[boulderIdx].tickCount += 1
        walls[wallIdx].updatedAt = Date()
        try await persist()
    }

    func decrementBoulderTick(wallID: UUID, boulderID: UUID) async throws {
        guard let wallIdx = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let boulderIdx = walls[wallIdx].boulders.firstIndex(where: { $0.id == boulderID }) else {
            throw AppStoreError.boulderNotFound
        }

        guard walls[wallIdx].boulders[boulderIdx].tickCount > 0 else {
            return
        }
        walls[wallIdx].boulders[boulderIdx].tickCount -= 1
        walls[wallIdx].updatedAt = Date()
        try await persist()
    }

    func exportBackupData() throws -> Data {
        let backupWalls = try walls.map { wall -> BackupWall in
            guard let imageData = imageStore.loadImageData(filename: wall.imageFilename) else {
                throw AppStoreError.missingWallImage
            }

            let maskDataBase64: String?
            if let maskFilename = wall.maskFilename {
                maskDataBase64 = imageStore.loadImageData(filename: maskFilename)?.base64EncodedString()
            } else {
                maskDataBase64 = nil
            }

            return BackupWall(
                wall: wall,
                imageDataBase64: imageData.base64EncodedString(),
                maskDataBase64: maskDataBase64
            )
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

            if let maskDataBase64 = backupWall.maskDataBase64,
               let maskData = Data(base64Encoded: maskDataBase64),
               UIImage(data: maskData) != nil {
                wall.maskFilename = try imageStore.saveMaskImageData(maskData, for: wall.id)
            } else {
                wall.maskFilename = nil
            }

            importedWalls.append(wall)
        }

        imageCache.removeAllObjects()
        maskCache.removeAllObjects()
        walls = importedWalls.sorted { $0.updatedAt > $1.updatedAt }
        try await persist()
    }

    private func wallIndex(for wallID: UUID) -> Int? {
        walls.firstIndex { $0.id == wallID }
    }

    private func detectionImage(for wall: Wall) -> UIImage? {
        guard let baseImage = image(for: wall) else {
            return nil
        }
        guard let maskImage = mask(for: wall) else {
            return baseImage
        }

        return maskedImage(baseImage, with: maskImage) ?? baseImage
    }

    private func maskedImage(_ image: UIImage, with mask: UIImage) -> UIImage? {
        guard let sourceImage = normalizedImage(image),
              let maskImage = normalizedImage(mask),
              let sourceCI = CIImage(image: sourceImage),
              let maskCI = CIImage(image: maskImage) else {
            return nil
        }

        let targetRect = CGRect(origin: .zero, size: sourceImage.size)
        guard targetRect.width > 1, targetRect.height > 1 else {
            return nil
        }

        let sx = targetRect.width / max(maskCI.extent.width, 1)
        let sy = targetRect.height / max(maskCI.extent.height, 1)
        let scaledMask = maskCI
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: targetRect)
        let blackBackground = CIImage(color: CIColor.black).cropped(to: targetRect)
        let output = sourceCI.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputMaskImageKey: scaledMask,
                kCIInputBackgroundImageKey: blackBackground
            ]
        )

        guard let cgImage = ciContext.createCGImage(output, from: targetRect) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: sourceImage.scale, orientation: .up)
    }

    private func normalizedImage(_ image: UIImage) -> UIImage? {
        if image.imageOrientation == .up {
            return image
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered
    }

    private func manualRingMarker(at normalizedPoint: CGPoint) -> Hold {
        let markerSize: CGFloat = 0.05
        let rect = NormalizedRect(
            x: normalizedPoint.x - (markerSize / 2),
            y: normalizedPoint.y - (markerSize / 2),
            width: markerSize,
            height: markerSize
        ).clamped()

        let contour = ringContour(around: normalizedPoint)
        return Hold(
            rect: rect,
            contour: contour.isEmpty ? nil : contour,
            confidence: 0.2,
            source: .manual
        )
    }

    private func ringContour(around normalizedPoint: CGPoint) -> [NormalizedPoint] {
        let radius: CGFloat = 0.019
        let pointCount = 18

        var contour: [NormalizedPoint] = []
        contour.reserveCapacity(pointCount)

        for index in 0..<pointCount {
            let angle = (-CGFloat.pi / 2) + (CGFloat(index) * (.pi * 2) / CGFloat(pointCount))
            let contourPoint = NormalizedPoint(
                x: normalizedPoint.x + (cos(angle) * radius),
                y: normalizedPoint.y + (sin(angle) * radius)
            ).clamped()

            if contour.last != contourPoint {
                contour.append(contourPoint)
            }
        }

        return contour.count >= 3 ? contour : []
    }

    private func movedHold(_ hold: Hold, to normalizedCenter: CGPoint) -> Hold {
        let currentCenter = CGPoint(
            x: hold.rect.x + (hold.rect.width / 2),
            y: hold.rect.y + (hold.rect.height / 2)
        )
        let requestedDx = normalizedCenter.x - currentCenter.x
        let requestedDy = normalizedCenter.y - currentCenter.y

        var moved = hold
        moved.rect = NormalizedRect(
            x: hold.rect.x + requestedDx,
            y: hold.rect.y + requestedDy,
            width: hold.rect.width,
            height: hold.rect.height
        ).clamped()

        let updatedCenter = CGPoint(
            x: moved.rect.x + (moved.rect.width / 2),
            y: moved.rect.y + (moved.rect.height / 2)
        )
        let appliedDx = updatedCenter.x - currentCenter.x
        let appliedDy = updatedCenter.y - currentCenter.y

        if let contour = hold.contour {
            moved.contour = contour.map { point in
                NormalizedPoint(x: point.x + appliedDx, y: point.y + appliedDy).clamped()
            }
        }

        return moved
    }

    private func decimatedContour(_ points: [CGPoint], maxCount: Int) -> [CGPoint] {
        guard maxCount > 2, points.count > maxCount else {
            return points
        }

        var result: [CGPoint] = []
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

    private func persist() async throws {
        walls.sort { $0.updatedAt > $1.updatedAt }
        try await repository.saveWalls(walls)
    }
}
