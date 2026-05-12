import Foundation
import UIKit

struct SessionLogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let recordedAt: Date
    let duration: TimeInterval
    let attempts: Int
    let ticks: Int

    init(
        id: UUID = UUID(),
        recordedAt: Date,
        duration: TimeInterval,
        attempts: Int,
        ticks: Int
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.duration = max(0, duration)
        self.attempts = max(0, attempts)
        self.ticks = max(0, ticks)
    }
}

@MainActor
final class AppStore: ObservableObject {
    enum AppStoreError: LocalizedError {
        case invalidImage
        case wallNotFound
        case boulderNotFound
        case missingWallImage
        case noHoldsDetected
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
            case .noHoldsDetected:
                return "No holds were detected. Try marking holds manually."
            case .invalidBackupData:
                return "The backup file is corrupted or unsupported."
            case .unsupportedBackupVersion:
                return "This backup version is not supported by the current app."
            }
        }
    }

    private struct BackupPayload: Codable {
        static let currentVersion = 2

        let version: Int
        let exportedAt: Date
        let walls: [BackupWall]
        let sessionLogs: [SessionLogEntry]

        private enum CodingKeys: String, CodingKey {
            case version
            case exportedAt
            case walls
            case sessionLogs
        }

        init(version: Int, exportedAt: Date, walls: [BackupWall], sessionLogs: [SessionLogEntry]) {
            self.version = version
            self.exportedAt = exportedAt
            self.walls = walls
            self.sessionLogs = sessionLogs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            exportedAt = try container.decode(Date.self, forKey: .exportedAt)
            walls = try container.decode([BackupWall].self, forKey: .walls)
            sessionLogs = try container.decodeIfPresent([SessionLogEntry].self, forKey: .sessionLogs) ?? []
        }
    }

    private struct BackupWall: Codable {
        let wall: Wall
        let imageDataBase64: String
    }

    @Published private(set) var walls: [Wall] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var sessionLogs: [SessionLogEntry] = []
    @Published private(set) var sessionStartDate: Date?
    @Published private(set) var sessionAccumulatedDuration: TimeInterval = 0

    private let repository: WallRepository
    private let imageStore: ImageStore
    private let holdDetector: OfflineHoldDetectionService
    private let userDefaults: UserDefaults
    private let imageCache = NSCache<NSString, UIImage>()
    private let sessionLogsKey = "sessionLogs"
    private var sessionStartedAt: Date?
    private var sessionAttemptCount = 0
    private var sessionTickCount = 0

    init(
        repository: WallRepository = WallRepository(),
        imageStore: ImageStore = ImageStore(),
        holdDetector: OfflineHoldDetectionService = OfflineHoldDetectionService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.imageStore = imageStore
        self.holdDetector = holdDetector
        self.userDefaults = userDefaults

        Task {
            await load()
        }
    }

    func load() async {
        do {
            let loadedWalls = try await repository.loadWalls()
            walls = loadedWalls.sorted { $0.updatedAt > $1.updatedAt }
            sessionLogs = loadSessionLogs()
            hasLoaded = true
        } catch {
            walls = []
            sessionLogs = loadSessionLogs()
            hasLoaded = true
        }
    }

    func wall(withID id: UUID) -> Wall? {
        walls.first { $0.id == id }
    }

    var isSessionRunning: Bool {
        sessionStartDate != nil
    }

    func currentSessionDuration(at referenceDate: Date = Date()) -> TimeInterval {
        sessionAccumulatedDuration + (sessionStartDate.map { referenceDate.timeIntervalSince($0) } ?? 0)
    }

    func startSession() {
        guard sessionStartDate == nil else {
            return
        }
        let now = Date()
        if sessionStartedAt == nil {
            sessionStartedAt = now
        }
        sessionStartDate = now
    }

    func pauseSession() {
        guard let sessionStartDate else {
            return
        }
        sessionAccumulatedDuration += Date().timeIntervalSince(sessionStartDate)
        self.sessionStartDate = nil
    }

    func resetSession() {
        finalizeSessionIfNeeded()
        sessionStartDate = nil
        sessionAccumulatedDuration = 0
        sessionStartedAt = nil
        sessionAttemptCount = 0
        sessionTickCount = 0
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

    func detectHolds(for wallID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let image = image(for: walls[index]) else {
            throw AppStoreError.missingWallImage
        }

        let detected = try await holdDetector.detectHolds(in: image)
        guard !detected.isEmpty else {
            throw AppStoreError.noHoldsDetected
        }

        walls[index].holds = detected
        walls[index].updatedAt = Date()
        try await persist()
    }

    func removeLastManualHold(wallID: UUID) async throws {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let lastIndex = walls[index].holds.indices.last else {
            return
        }
        walls[index].holds.remove(at: lastIndex)
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

        let newHold = manualBoxHold(at: point)
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

    func resizeHold(wallID: UUID, holdID: UUID, to normalizedRect: NormalizedRect) async throws {
        guard let wallIndex = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let holdIndex = walls[wallIndex].holds.firstIndex(where: { $0.id == holdID }) else {
            return
        }

        walls[wallIndex].holds[holdIndex] = resizedHold(
            walls[wallIndex].holds[holdIndex],
            to: normalizedRect.clamped()
        )
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
            confidence: 0.85
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

        walls[wallIdx].boulders[boulderIdx].attemptCount += 1
        walls[wallIdx].boulders[boulderIdx].tickCount += 1
        appendLogEntry(attempts: 1, ticks: 1, toBoulderAt: boulderIdx, onWallAt: wallIdx)
        adjustSessionActivity(attempts: 1, ticks: 1)
        walls[wallIdx].updatedAt = Date()
        try await persist()
    }

    func incrementBoulderAttempt(wallID: UUID, boulderID: UUID) async throws {
        guard let wallIdx = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let boulderIdx = walls[wallIdx].boulders.firstIndex(where: { $0.id == boulderID }) else {
            throw AppStoreError.boulderNotFound
        }

        walls[wallIdx].boulders[boulderIdx].attemptCount += 1
        appendLogEntry(attempts: 1, ticks: 0, toBoulderAt: boulderIdx, onWallAt: wallIdx)
        adjustSessionActivity(attempts: 1, ticks: 0)
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

        if let removedEntry = removeLastLogEntry(
            matching: { $0.ticks > 0 },
            fromBoulderAt: boulderIdx,
            onWallAt: wallIdx
        ) {
            walls[wallIdx].boulders[boulderIdx].tickCount = max(
                0,
                walls[wallIdx].boulders[boulderIdx].tickCount - removedEntry.ticks
            )
            walls[wallIdx].boulders[boulderIdx].attemptCount = max(
                0,
                walls[wallIdx].boulders[boulderIdx].attemptCount - removedEntry.attempts
            )
            adjustSessionActivity(attempts: -removedEntry.attempts, ticks: -removedEntry.ticks)
        } else {
            walls[wallIdx].boulders[boulderIdx].tickCount -= 1
            walls[wallIdx].boulders[boulderIdx].attemptCount = max(
                0,
                walls[wallIdx].boulders[boulderIdx].attemptCount - 1
            )
            adjustSessionActivity(attempts: -1, ticks: -1)
        }
        walls[wallIdx].updatedAt = Date()
        try await persist()
    }

    func decrementBoulderAttempt(wallID: UUID, boulderID: UUID) async throws {
        guard let wallIdx = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }
        guard let boulderIdx = walls[wallIdx].boulders.firstIndex(where: { $0.id == boulderID }) else {
            throw AppStoreError.boulderNotFound
        }

        guard walls[wallIdx].boulders[boulderIdx].attemptCount > 0 else {
            return
        }

        if let removedEntry = removeLastLogEntry(
            matching: { $0.attempts > 0 && $0.ticks == 0 },
            fromBoulderAt: boulderIdx,
            onWallAt: wallIdx
        ) {
            walls[wallIdx].boulders[boulderIdx].attemptCount = max(
                0,
                walls[wallIdx].boulders[boulderIdx].attemptCount - removedEntry.attempts
            )
            adjustSessionActivity(attempts: -removedEntry.attempts, ticks: 0)
        } else {
            return
        }
        walls[wallIdx].updatedAt = Date()
        try await persist()
    }

    func exportBackupData() throws -> Data {
        let backupWalls = try walls.map { wall -> BackupWall in
            guard let imageData = imageStore.loadImageData(filename: wall.imageFilename) else {
                throw AppStoreError.missingWallImage
            }

            return BackupWall(
                wall: wall,
                imageDataBase64: imageData.base64EncodedString()
            )
        }

        let payload = BackupPayload(
            version: BackupPayload.currentVersion,
            exportedAt: Date(),
            walls: backupWalls,
            sessionLogs: sessionLogs
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

        guard (1...BackupPayload.currentVersion).contains(payload.version) else {
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
        sessionLogs = payload.sessionLogs
        saveSessionLogs()
        sessionStartDate = nil
        sessionAccumulatedDuration = 0
        sessionStartedAt = nil
        sessionAttemptCount = 0
        sessionTickCount = 0
        try await persist()
    }

    private func wallIndex(for wallID: UUID) -> Int? {
        walls.firstIndex { $0.id == wallID }
    }

    private func manualBoxHold(at normalizedPoint: CGPoint) -> Hold {
        let rect = NormalizedRect(
            x: normalizedPoint.x - 0.04,
            y: normalizedPoint.y - 0.03,
            width: 0.08,
            height: 0.06
        ).clamped()

        return Hold(
            rect: rect,
            contour: nil,
            confidence: 0.35
        )
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

    private func resizedHold(_ hold: Hold, to normalizedRect: NormalizedRect) -> Hold {
        let clampedRect = normalizedRect.clamped()
        var resized = hold
        let previousRect = hold.rect
        resized.rect = clampedRect

        guard let contour = hold.contour,
              previousRect.width > 0.0001,
              previousRect.height > 0.0001 else {
            resized.contour = nil
            return resized
        }

        resized.contour = contour.map { point in
            let normalizedX = (point.x - previousRect.x) / previousRect.width
            let normalizedY = (point.y - previousRect.y) / previousRect.height
            return NormalizedPoint(
                x: clampedRect.x + (normalizedX * clampedRect.width),
                y: clampedRect.y + (normalizedY * clampedRect.height)
            ).clamped()
        }
        return resized
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

    private func adjustSessionActivity(attempts: Int, ticks: Int) {
        guard sessionStartedAt != nil else {
            return
        }

        sessionAttemptCount = max(0, sessionAttemptCount + attempts)
        sessionTickCount = max(0, sessionTickCount + ticks)
    }

    private func finalizeSessionIfNeeded() {
        guard let sessionStartedAt else {
            return
        }

        let duration = currentSessionDuration()
        guard duration >= 1 || sessionAttemptCount > 0 || sessionTickCount > 0 else {
            return
        }

        sessionLogs.insert(
            SessionLogEntry(
                recordedAt: sessionStartedAt,
                duration: duration,
                attempts: sessionAttemptCount,
                ticks: sessionTickCount
            ),
            at: 0
        )
        saveSessionLogs()
    }

    private func loadSessionLogs() -> [SessionLogEntry] {
        guard let data = userDefaults.data(forKey: sessionLogsKey) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SessionLogEntry].self, from: data)) ?? []
    }

    private func saveSessionLogs() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(sessionLogs) else {
            return
        }

        userDefaults.set(data, forKey: sessionLogsKey)
    }

    private func appendLogEntry(attempts: Int, ticks: Int, toBoulderAt boulderIndex: Int, onWallAt wallIndex: Int) {
        walls[wallIndex].boulders[boulderIndex].logEntries.append(
            BoulderLogEntry(attempts: attempts, ticks: ticks)
        )
    }

    private func removeLastLogEntry(
        matching predicate: (BoulderLogEntry) -> Bool,
        fromBoulderAt boulderIndex: Int,
        onWallAt wallIndex: Int
    ) -> BoulderLogEntry? {
        guard let logIndex = walls[wallIndex].boulders[boulderIndex].logEntries.lastIndex(where: predicate) else {
            return nil
        }

        return walls[wallIndex].boulders[boulderIndex].logEntries.remove(at: logIndex)
    }
}
