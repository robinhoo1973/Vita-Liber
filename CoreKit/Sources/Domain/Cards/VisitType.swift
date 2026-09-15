import Foundation

public enum VisitType: String, Codable, Sendable {
    case firstVisit = "初诊"
    case revisit    = "复诊"
    case emergency  = "急诊"
}
