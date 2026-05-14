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

struct BoulderImportCandidate: Identifiable, Hashable {
    let id: String
    let sourceWallID: UUID
    let sourceWallName: String
    let sourceBoulder: Boulder
    let matchedHoldIDs: [UUID]
    let missingHoldCount: Int
    let totalHoldCount: Int

    var isComplete: Bool {
        missingHoldCount == 0 && totalHoldCount > 0
    }

    var matchedHoldCount: Int {
        matchedHoldIDs.count
    }
}

private struct HoldGeometryTransform {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let d: CGFloat
    let tx: CGFloat
    let ty: CGFloat

    static let identity = HoldGeometryTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    func applying(to point: CGPoint) -> CGPoint {
        CGPoint(
            x: (a * point.x) + (b * point.y) + tx,
            y: (c * point.x) + (d * point.y) + ty
        )
    }

    func applying(to rect: NormalizedRect) -> NormalizedRect {
        let source = rect.cgRect
        let points = [
            CGPoint(x: source.minX, y: source.minY),
            CGPoint(x: source.maxX, y: source.minY),
            CGPoint(x: source.maxX, y: source.maxY),
            CGPoint(x: source.minX, y: source.maxY)
        ].map { applying(to: $0) }

        let minX = points.map(\.x).min() ?? source.minX
        let maxX = points.map(\.x).max() ?? source.maxX
        let minY = points.map(\.y).min() ?? source.minY
        let maxY = points.map(\.y).max() ?? source.maxY
        return NormalizedRect(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY)
        ).clamped()
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

    @discardableResult
    func addSmartMarkerHold(wallID: UUID, at normalizedPoint: CGPoint) async throws -> UUID {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }

        let point = CGPoint(
            x: min(max(0, normalizedPoint.x), 1),
            y: min(max(0, normalizedPoint.y), 1)
        )
        if let existingHold = hold(at: point, in: walls[index].holds) {
            return existingHold.id
        }

        let image = image(for: walls[index])
        let newHold: Hold
        if let image,
           let detectedHold = try await holdDetector.detectHold(in: image, at: point) {
            if overlappingHold(for: detectedHold, in: walls[index].holds) != nil {
                newHold = manualBoxHold(at: point)
            } else {
                newHold = detectedHold
            }
        } else {
            newHold = manualBoxHold(at: point)
        }

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

    func boulderImportCandidates(for wallID: UUID) -> [BoulderImportCandidate] {
        guard let targetWall = wall(withID: wallID), !targetWall.holds.isEmpty else {
            return []
        }

        let existingSignatures = Set(targetWall.boulders.map { boulderSignature(for: $0, holdIDs: $0.holdIDs) })
        return walls
            .filter { $0.id != wallID }
            .flatMap { sourceWall in
                let transform = bestGeometryTransform(from: sourceWall.holds, to: targetWall.holds)
                return sourceWall.boulders.compactMap { boulder in
                    importCandidate(
                        from: boulder,
                        sourceWall: sourceWall,
                        targetWall: targetWall,
                        existingSignatures: existingSignatures,
                        transform: transform
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.isComplete != rhs.isComplete {
                    return lhs.isComplete
                }
                if lhs.missingHoldCount != rhs.missingHoldCount {
                    return lhs.missingHoldCount < rhs.missingHoldCount
                }
                if lhs.sourceWallName != rhs.sourceWallName {
                    return lhs.sourceWallName.localizedCaseInsensitiveCompare(rhs.sourceWallName) == .orderedAscending
                }
                return lhs.sourceBoulder.createdAt > rhs.sourceBoulder.createdAt
            }
    }

    @discardableResult
    func importBoulders(_ candidates: [BoulderImportCandidate], into wallID: UUID) async throws -> Int {
        guard let index = wallIndex(for: wallID) else {
            throw AppStoreError.wallNotFound
        }

        let targetHoldIDs = Set(walls[index].holds.map(\.id))
        let imported = candidates.compactMap { candidate -> Boulder? in
            let holdIDs = candidate.matchedHoldIDs.filter { targetHoldIDs.contains($0) }
            guard !holdIDs.isEmpty else {
                return nil
            }

            return Boulder(
                wallID: wallID,
                name: candidate.sourceBoulder.name,
                grade: candidate.sourceBoulder.grade,
                notes: importedNotes(for: candidate),
                holdIDs: holdIDs,
                attemptCount: candidate.sourceBoulder.attemptCount,
                tickCount: candidate.sourceBoulder.tickCount,
                logEntries: candidate.sourceBoulder.logEntries,
                createdAt: candidate.sourceBoulder.createdAt
            )
        }

        guard !imported.isEmpty else {
            return 0
        }

        walls[index].boulders.insert(contentsOf: imported, at: 0)
        walls[index].updatedAt = Date()
        try await persist()
        return imported.count
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

    private func importCandidate(
        from boulder: Boulder,
        sourceWall: Wall,
        targetWall: Wall,
        existingSignatures: Set<String>,
        transform: HoldGeometryTransform
    ) -> BoulderImportCandidate? {
        let sourceHoldsByID = Dictionary(uniqueKeysWithValues: sourceWall.holds.map { ($0.id, $0) })
        var usedTargetHoldIDs = Set<UUID>()
        var matchedHoldIDs: [UUID] = []
        var missingHoldCount = 0

        for holdID in boulder.holdIDs {
            guard let sourceHold = sourceHoldsByID[holdID],
                  let targetHold = bestMatchingHold(
                    for: sourceHold,
                    transform: transform,
                    in: targetWall.holds,
                    excluding: usedTargetHoldIDs
                  ) else {
                missingHoldCount += 1
                continue
            }

            usedTargetHoldIDs.insert(targetHold.id)
            matchedHoldIDs.append(targetHold.id)
        }

        guard !matchedHoldIDs.isEmpty else {
            return nil
        }

        let totalHoldCount = boulder.holdIDs.count
        let candidate = BoulderImportCandidate(
            id: "\(sourceWall.id.uuidString)-\(boulder.id.uuidString)",
            sourceWallID: sourceWall.id,
            sourceWallName: sourceWall.name,
            sourceBoulder: boulder,
            matchedHoldIDs: matchedHoldIDs,
            missingHoldCount: missingHoldCount,
            totalHoldCount: totalHoldCount
        )

        guard !existingSignatures.contains(boulderSignature(for: boulder, holdIDs: matchedHoldIDs)) else {
            return nil
        }
        return candidate
    }

    private func bestMatchingHold(
        for sourceHold: Hold,
        transform: HoldGeometryTransform,
        in targetHolds: [Hold],
        excluding usedIDs: Set<UUID>
    ) -> Hold? {
        let transformedRect = transform.applying(to: sourceHold.rect)
        return targetHolds
            .filter { !usedIDs.contains($0.id) }
            .compactMap { targetHold -> (hold: Hold, score: CGFloat)? in
                let score = holdMatchScore(transformedRect, targetHold.rect)
                guard score >= 0.38 else {
                    return nil
                }
                return (targetHold, score)
            }
            .max { lhs, rhs in
                lhs.score < rhs.score
            }?
            .hold
    }

    private func bestGeometryTransform(from sourceHolds: [Hold], to targetHolds: [Hold]) -> HoldGeometryTransform {
        let candidates = geometryTransformCandidates(from: sourceHolds, to: targetHolds)
        return candidates.max { lhs, rhs in
            geometryTransformScore(lhs, sourceHolds: sourceHolds, targetHolds: targetHolds)
                < geometryTransformScore(rhs, sourceHolds: sourceHolds, targetHolds: targetHolds)
        } ?? .identity
    }

    private func geometryTransformCandidates(from sourceHolds: [Hold], to targetHolds: [Hold]) -> [HoldGeometryTransform] {
        var candidates: [HoldGeometryTransform] = [.identity]

        if let boundsTransform = boundsTransform(from: sourceHolds, to: targetHolds) {
            candidates.append(boundsTransform)
        }
        candidates.append(contentsOf: principalAxisTransforms(from: sourceHolds, to: targetHolds))
        return candidates
    }

    private func geometryTransformScore(
        _ transform: HoldGeometryTransform,
        sourceHolds: [Hold],
        targetHolds: [Hold]
    ) -> CGFloat {
        guard !sourceHolds.isEmpty, !targetHolds.isEmpty else {
            return 0
        }

        var totalScore: CGFloat = 0
        var matchedCount = 0
        for sourceHold in sourceHolds {
            let transformedRect = transform.applying(to: sourceHold.rect)
            let bestScore = targetHolds
                .map { holdMatchScore(transformedRect, $0.rect) }
                .max() ?? 0
            if bestScore >= 0.34 {
                matchedCount += 1
                totalScore += bestScore
            }
        }

        return (CGFloat(matchedCount) * 12) + totalScore
    }

    private func boundsTransform(from sourceHolds: [Hold], to targetHolds: [Hold]) -> HoldGeometryTransform? {
        guard let sourceBounds = centerBounds(for: sourceHolds),
              let targetBounds = centerBounds(for: targetHolds),
              sourceBounds.width > 0.01,
              sourceBounds.height > 0.01 else {
            return nil
        }

        let scaleX = targetBounds.width / sourceBounds.width
        let scaleY = targetBounds.height / sourceBounds.height
        return HoldGeometryTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: targetBounds.midX - (sourceBounds.midX * scaleX),
            ty: targetBounds.midY - (sourceBounds.midY * scaleY)
        )
    }

    private func principalAxisTransforms(from sourceHolds: [Hold], to targetHolds: [Hold]) -> [HoldGeometryTransform] {
        guard let sourceStats = principalAxisStats(for: sourceHolds),
              let targetStats = principalAxisStats(for: targetHolds),
              sourceStats.spreadX > 0.005,
              sourceStats.spreadY > 0.005 else {
            return []
        }

        let scaleX = targetStats.spreadX / sourceStats.spreadX
        let scaleY = targetStats.spreadY / sourceStats.spreadY
        let signPairs: [(CGFloat, CGFloat)] = [(1, 1), (-1, 1), (1, -1), (-1, -1)]
        return signPairs.map { signX, signY in
            affineTransform(
                source: sourceStats,
                target: targetStats,
                scaleX: scaleX * signX,
                scaleY: scaleY * signY
            )
        }
    }

    private func affineTransform(
        source: PrincipalAxisStats,
        target: PrincipalAxisStats,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> HoldGeometryTransform {
        let sx1 = source.axisX
        let sy1 = source.axisY
        let tx1 = target.axisX
        let ty1 = target.axisY

        let a = (tx1.dx * scaleX * sx1.dx) + (ty1.dx * scaleY * sy1.dx)
        let b = (tx1.dx * scaleX * sx1.dy) + (ty1.dx * scaleY * sy1.dy)
        let c = (tx1.dy * scaleX * sx1.dx) + (ty1.dy * scaleY * sy1.dx)
        let d = (tx1.dy * scaleX * sx1.dy) + (ty1.dy * scaleY * sy1.dy)
        let mappedSourceMean = CGPoint(
            x: (a * source.mean.x) + (b * source.mean.y),
            y: (c * source.mean.x) + (d * source.mean.y)
        )

        return HoldGeometryTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: target.mean.x - mappedSourceMean.x,
            ty: target.mean.y - mappedSourceMean.y
        )
    }

    private struct PrincipalAxisStats {
        let mean: CGPoint
        let axisX: CGVector
        let axisY: CGVector
        let spreadX: CGFloat
        let spreadY: CGFloat
    }

    private func principalAxisStats(for holds: [Hold]) -> PrincipalAxisStats? {
        let points = holds.map { center(of: $0.rect) }
        guard points.count >= 3 else {
            return nil
        }

        let mean = CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
        )
        var xx: CGFloat = 0
        var xy: CGFloat = 0
        var yy: CGFloat = 0
        for point in points {
            let dx = point.x - mean.x
            let dy = point.y - mean.y
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }

        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let axisX = CGVector(dx: cos(angle), dy: sin(angle))
        let axisY = CGVector(dx: -sin(angle), dy: cos(angle))
        let projectedX = points.map { (($0.x - mean.x) * axisX.dx) + (($0.y - mean.y) * axisX.dy) }
        let projectedY = points.map { (($0.x - mean.x) * axisY.dx) + (($0.y - mean.y) * axisY.dy) }
        let spreadX = robustSpread(projectedX)
        let spreadY = robustSpread(projectedY)
        return PrincipalAxisStats(mean: mean, axisX: axisX, axisY: axisY, spreadX: spreadX, spreadY: spreadY)
    }

    private func centerBounds(for holds: [Hold]) -> CGRect? {
        let points = holds.map { center(of: $0.rect) }
        guard points.count >= 2 else {
            return nil
        }

        let xs = points.map(\.x).sorted()
        let ys = points.map(\.y).sorted()
        let minX = percentile(xs, 0.08)
        let maxX = percentile(xs, 0.92)
        let minY = percentile(ys, 0.08)
        let maxY = percentile(ys, 0.92)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func center(of rect: NormalizedRect) -> CGPoint {
        CGPoint(x: rect.x + (rect.width / 2), y: rect.y + (rect.height / 2))
    }

    private func robustSpread(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard sorted.count >= 2 else {
            return 0
        }
        return max(0.0001, percentile(sorted, 0.92) - percentile(sorted, 0.08))
    }

    private func percentile(_ sortedValues: [CGFloat], _ percentile: CGFloat) -> CGFloat {
        guard !sortedValues.isEmpty else {
            return 0
        }
        let clamped = min(max(0, percentile), 1)
        let rawIndex = clamped * CGFloat(sortedValues.count - 1)
        let lowerIndex = Int(floor(rawIndex))
        let upperIndex = Int(ceil(rawIndex))
        guard lowerIndex != upperIndex else {
            return sortedValues[lowerIndex]
        }
        let fraction = rawIndex - CGFloat(lowerIndex)
        return sortedValues[lowerIndex] + ((sortedValues[upperIndex] - sortedValues[lowerIndex]) * fraction)
    }

    private func holdMatchScore(_ sourceRect: NormalizedRect, _ targetRect: NormalizedRect) -> CGFloat {
        let source = sourceRect.cgRect
        let target = targetRect.cgRect
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let targetCenter = CGPoint(x: target.midX, y: target.midY)
        let distance = hypot(sourceCenter.x - targetCenter.x, sourceCenter.y - targetCenter.y)
        let sourceArea = max(source.width * source.height, 0.0001)
        let targetArea = max(target.width * target.height, 0.0001)
        let sizeScale = max(0.025, min(0.07, max(source.width, source.height, target.width, target.height) * 0.85))
        let distanceScore = max(0, 1 - (distance / sizeScale))

        let intersection = source.intersection(target)
        let overlapScore: CGFloat
        if intersection.isNull || intersection.width <= 0 || intersection.height <= 0 {
            overlapScore = 0
        } else {
            let overlapArea = intersection.width * intersection.height
            let containment = overlapArea / min(sourceArea, targetArea)
            let iou = overlapArea / max(sourceArea + targetArea - overlapArea, 0.0001)
            overlapScore = max(containment, iou * 1.6)
        }

        return max(distanceScore, overlapScore)
    }

    private func boulderSignature(for boulder: Boulder, holdIDs: [UUID]) -> String {
        [
            boulder.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            boulder.grade.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            holdIDs.map(\.uuidString).sorted().joined(separator: ",")
        ].joined(separator: "|")
    }

    private func importedNotes(for candidate: BoulderImportCandidate) -> String {
        let notes = candidate.sourceBoulder.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isComplete else {
            return notes
        }

        let missingText = candidate.missingHoldCount == 1 ? "1 hold missing" : "\(candidate.missingHoldCount) holds missing"
        let importNote = "Imported from \(candidate.sourceWallName); \(missingText)."
        return notes.isEmpty ? importNote : "\(notes)\n\n\(importNote)"
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

    private func overlappingHold(for hold: Hold, in existingHolds: [Hold]) -> Hold? {
        existingHolds
            .compactMap { existingHold -> (hold: Hold, score: CGFloat)? in
                let overlap = hold.rect.cgRect.intersection(existingHold.rect.cgRect)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
                    return nil
                }

                let overlapArea = overlap.width * overlap.height
                let holdArea = max(hold.rect.width * hold.rect.height, 0.0001)
                let existingArea = max(existingHold.rect.width * existingHold.rect.height, 0.0001)
                let smallerOverlap = overlapArea / min(holdArea, existingArea)
                let unionOverlap = overlapArea / max(holdArea + existingArea - overlapArea, 0.0001)
                guard smallerOverlap >= 0.25 || unionOverlap >= 0.12 else {
                    return nil
                }
                return (existingHold, max(smallerOverlap, unionOverlap))
            }
            .max { lhs, rhs in
                lhs.score < rhs.score
            }?
            .hold
    }

    private func hold(at point: CGPoint, in existingHolds: [Hold]) -> Hold? {
        existingHolds.reversed().first { hold in
            hold.rect.cgRect.insetBy(dx: -0.004, dy: -0.004).contains(point)
        }
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
