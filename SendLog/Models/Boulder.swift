import Foundation

struct Boulder: Identifiable, Codable, Hashable {
    let id: UUID
    let wallID: UUID
    var name: String
    var grade: String
    var notes: String
    var holdIDs: [UUID]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        wallID: UUID,
        name: String,
        grade: String,
        notes: String,
        holdIDs: [UUID],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.wallID = wallID
        self.name = name
        self.grade = grade
        self.notes = notes
        self.holdIDs = holdIDs
        self.createdAt = createdAt
    }
}
