import Foundation

struct Wall: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var imageFilename: String
    var holds: [Hold]
    var wallEdges: [[NormalizedPoint]]
    var boulders: [Boulder]
    let createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case imageFilename
        case holds
        case wallEdges
        case boulders
        case createdAt
        case updatedAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        imageFilename: String,
        holds: [Hold] = [],
        wallEdges: [[NormalizedPoint]] = [],
        boulders: [Boulder] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.imageFilename = imageFilename
        self.holds = holds
        self.wallEdges = wallEdges
        self.boulders = boulders
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        imageFilename = try container.decode(String.self, forKey: .imageFilename)
        holds = try container.decodeIfPresent([Hold].self, forKey: .holds) ?? []
        wallEdges = try container.decodeIfPresent([[NormalizedPoint]].self, forKey: .wallEdges) ?? []
        boulders = try container.decodeIfPresent([Boulder].self, forKey: .boulders) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(imageFilename, forKey: .imageFilename)
        try container.encode(holds, forKey: .holds)
        try container.encode(wallEdges, forKey: .wallEdges)
        try container.encode(boulders, forKey: .boulders)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
