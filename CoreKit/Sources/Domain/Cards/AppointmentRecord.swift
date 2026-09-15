import Foundation

public struct AppointmentRecord: InformationCard {
    public static let cardType = "appointment"

    public var cardId: String = UUID().uuidString
    public var patientId: String?
    public var source: DataSource = .manual
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var appointmentType: AppointmentType = .visit
    public var department: String?
    public var doctorName: String?
    public var appointmentDate: Date = Date()
    public var appointmentTime: String = ""
    public var appointmentLocation: String?
    public var status: AppointmentStatus = .booked
    public var cancelReason: String?
    public var encounterId: String?

    public init() {}
}

public enum AppointmentType: String, Codable, Sendable {
    case visit      = "1"
    case healthExam = "2"
    case revisit    = "3"
}

public enum AppointmentStatus: String, Codable, Sendable {
    case booked      = "0"
    case confirmed   = "1"
    case completed   = "2"
    case cancelled   = "3"
    case noShow      = "4"
    case rescheduled = "5"
}
