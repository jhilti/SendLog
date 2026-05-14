import Foundation

struct Wall: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var imageFilename: String
    var holds: [Hold]
    var boulders: [Boulder]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        imageFilename: String,
        holds: [Hold] = [],
        boulders: [Boulder] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.imageFilename = imageFilename
        self.holds = holds
        self.boulders = boulders
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
