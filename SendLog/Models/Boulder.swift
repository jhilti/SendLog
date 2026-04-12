import Foundation

struct BoulderLogEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let recordedAt: Date
    let attempts: Int
    let ticks: Int

    init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        attempts: Int,
        ticks: Int
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.attempts = max(0, attempts)
        self.ticks = max(0, ticks)
    }
}

struct Boulder: Identifiable, Codable, Hashable {
    let id: UUID
    let wallID: UUID
    var name: String
    var grade: String
    var notes: String
    var holdIDs: [UUID]
    var attemptCount: Int
    var tickCount: Int
    var logEntries: [BoulderLogEntry]
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case wallID
        case name
        case grade
        case notes
        case holdIDs
        case attemptCount
        case tickCount
        case logEntries
        case createdAt
    }

    init(
        id: UUID = UUID(),
        wallID: UUID,
        name: String,
        grade: String,
        notes: String,
        holdIDs: [UUID],
        attemptCount: Int = 0,
        tickCount: Int = 0,
        logEntries: [BoulderLogEntry] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.wallID = wallID
        self.name = name
        self.grade = grade
        self.notes = notes
        self.holdIDs = holdIDs
        self.attemptCount = max(0, attemptCount)
        self.tickCount = max(0, tickCount)
        self.logEntries = logEntries
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        wallID = try container.decode(UUID.self, forKey: .wallID)
        name = try container.decode(String.self, forKey: .name)
        grade = try container.decode(String.self, forKey: .grade)
        notes = try container.decode(String.self, forKey: .notes)
        holdIDs = try container.decode([UUID].self, forKey: .holdIDs)
        attemptCount = max(0, try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0)
        tickCount = max(0, try container.decodeIfPresent(Int.self, forKey: .tickCount) ?? 0)
        logEntries = try container.decodeIfPresent([BoulderLogEntry].self, forKey: .logEntries) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(wallID, forKey: .wallID)
        try container.encode(name, forKey: .name)
        try container.encode(grade, forKey: .grade)
        try container.encode(notes, forKey: .notes)
        try container.encode(holdIDs, forKey: .holdIDs)
        try container.encode(attemptCount, forKey: .attemptCount)
        try container.encode(tickCount, forKey: .tickCount)
        try container.encode(logEntries, forKey: .logEntries)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
