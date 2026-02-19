import Foundation

enum ClimbingGrade: String, CaseIterable, Codable, Hashable, Identifiable {
    case sixA = "6a"
    case sixAPlus = "6a+"
    case sixB = "6b"
    case sixBPlus = "6b+"
    case sixC = "6c"
    case sixCPlus = "6c+"
    case sevenA = "7a"
    case sevenAPlus = "7a+"
    case sevenB = "7b"
    case sevenBPlus = "7b+"
    case sevenC = "7c"
    case sevenCPlus = "7c+"
    case eightA = "8a"

    var id: String { rawValue }
}
