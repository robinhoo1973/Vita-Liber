import Foundation

public enum DataSource: String, Codable, Sendable {
    case manual
    case ocr
    case asr
    case hisImport
    case healthKit
    case wearable
    case unknown
}
