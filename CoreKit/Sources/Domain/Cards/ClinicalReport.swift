import Foundation

public struct ClinicalReport: InformationCard {
    public static let cardType = "clinical_report"

    public var cardId: String = UUID().uuidString
    public var patientId: String?
    public var source: DataSource = .manual
    public var confidence: Double = 1.0
    public var fieldConfidence: [String: Double] = [:]
    public var rawText: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var reportNo: String?
    public var reportSource: ReportSource = .outpatient
    public var reportType: ReportType = .lab
    public var orgCode: String?
    public var orgName: String?
    public var patientName: String?
    public var gender: String?
    public var age: String?
    public var reportDate: Date?
    public var reportDoctor: String?
    public var reviewDoctor: String?
    public var totalDoctor: String?
    public var clinicalDiagnosis: String?
    public var specimenType: String?
    public var specimenId: String?
    public var collectTime: Date?
    public var receiveTime: Date?
    public var overallConclusion: String?
    public var criticalFlag: Bool = false
    public var reportFilePath: String?
    public var remark: String?

    public var items: [ReportItem] = []
    public var conclusions: [ReportConclusion] = []

    public init() {}
}

public enum ReportSource: String, Codable, Sendable {
    case outpatient = "1"
    case inpatient  = "2"
    case healthExam = "3"
}

public enum ReportType: String, Codable, Sendable {
    case lab        = "1"
    case exam       = "2"
    case pathology  = "3"
    case healthExam = "4"
}

public struct ReportItem: Codable, Sendable, Identifiable {
    public var itemId: String = UUID().uuidString
    public var category: String?
    public var type: String?
    public var code: String?
    public var name: String
    public var value: String?
    public var unit: String?
    public var referenceRange: String?
    public var abnormalFlag: String?
    public var method: String?
    public var device: String?
    public var note: String?
    public var confidence: Double = 1.0

    public init(name: String, value: String? = nil, unit: String? = nil,
                referenceRange: String? = nil) {
        self.name = name
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
    }
}

public struct ReportConclusion: Codable, Sendable, Identifiable {
    public var conclusionId: String = UUID().uuidString
    public var type: String
    public var content: String
    public var severity: String?
    public var relatedItemIds: [String] = []

    public init(type: String, content: String, severity: String? = nil) {
        self.type = type
        self.content = content
        self.severity = severity
    }
}
