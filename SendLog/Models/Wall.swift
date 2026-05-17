import Foundation

struct WallSet: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var imageFilename: String
    var holds: [Hold]
    var wallEdges: [[NormalizedPoint]]
    var boulders: [Boulder]
    let createdAt: Date
    var updatedAt: Date
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        imageFilename: String,
        holds: [Hold] = [],
        wallEdges: [[NormalizedPoint]] = [],
        boulders: [Boulder] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.imageFilename = imageFilename
        self.holds = holds
        self.wallEdges = wallEdges
        self.boulders = boulders
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

struct Wall: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var activeSetID: UUID
    var sets: [WallSet]
    let createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case activeSetID
        case sets
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
        activeSetName: String = "Initial Set",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        let set = WallSet(
            name: activeSetName,
            imageFilename: imageFilename,
            holds: holds,
            wallEdges: wallEdges,
            boulders: boulders,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        self.activeSetID = set.id
        self.sets = [set]
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        if let decodedSets = try container.decodeIfPresent([WallSet].self, forKey: .sets), !decodedSets.isEmpty {
            sets = decodedSets
            let decodedActiveSetID = try container.decodeIfPresent(UUID.self, forKey: .activeSetID)
            activeSetID = decodedActiveSetID.flatMap { id in
                decodedSets.contains { $0.id == id } ? id : nil
            } ?? decodedSets[0].id
        } else {
            let imageFilename = try container.decode(String.self, forKey: .imageFilename)
            let holds = try container.decodeIfPresent([Hold].self, forKey: .holds) ?? []
            let wallEdges = try container.decodeIfPresent([[NormalizedPoint]].self, forKey: .wallEdges) ?? []
            let boulders = try container.decodeIfPresent([Boulder].self, forKey: .boulders) ?? []
            let setID = UUID()
            let migratedBoulders = boulders.map { boulder in
                var migrated = boulder
                migrated.wallSetID = setID
                return migrated
            }
            let migratedSet = WallSet(
                id: setID,
                name: "Initial Set",
                imageFilename: imageFilename,
                holds: holds,
                wallEdges: wallEdges,
                boulders: migratedBoulders,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            activeSetID = migratedSet.id
            sets = [migratedSet]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(activeSetID, forKey: .activeSetID)
        try container.encode(sets, forKey: .sets)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var activeSet: WallSet {
        get {
            sets.first { $0.id == activeSetID } ?? sets[0]
        }
        set {
            if let index = activeSetIndex {
                sets[index] = newValue
            }
        }
    }

    var imageFilename: String {
        get { activeSet.imageFilename }
        set { updateActiveSet { $0.imageFilename = newValue } }
    }

    var holds: [Hold] {
        get { activeSet.holds }
        set { updateActiveSet { $0.holds = newValue } }
    }

    var wallEdges: [[NormalizedPoint]] {
        get { activeSet.wallEdges }
        set { updateActiveSet { $0.wallEdges = newValue } }
    }

    var boulders: [Boulder] {
        get { activeSet.boulders }
        set { updateActiveSet { $0.boulders = newValue } }
    }

    var activeSetName: String {
        activeSet.name
    }

    var activeSetIndex: Int? {
        sets.firstIndex { $0.id == activeSetID }
    }

    mutating func activateSet(id: UUID) {
        guard sets.contains(where: { $0.id == id }) else {
            return
        }
        activeSetID = id
        updatedAt = Date()
    }

    mutating func appendSet(_ set: WallSet, activate: Bool = true) {
        sets.insert(set, at: 0)
        if activate {
            activeSetID = set.id
        }
        updatedAt = Date()
    }

    private mutating func updateActiveSet(_ update: (inout WallSet) -> Void) {
        guard let index = activeSetIndex else {
            return
        }
        update(&sets[index])
        sets[index].updatedAt = Date()
    }
}
