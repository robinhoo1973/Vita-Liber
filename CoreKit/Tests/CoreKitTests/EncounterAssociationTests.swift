import Foundation
import Testing
@testable import Domain

@Suite("FR4.2 卡内就诊建议与显式不关联")
struct EncounterAssociationTests {
    @Test func 同医院相似名可建议但同分与跨成员不预选() {
        let patient = UUID(), other = UUID(), first = UUID(), second = UUID()
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let a = EncounterResolver.Candidate(id: first, patientId: patient, date: date, hospital: "北京协和医院", doctor: "李医生")
        let foreign = EncounterResolver.Candidate(id: second, patientId: other, date: date, hospital: "协和医院", doctor: "李医生")
        #expect(EncounterResolver.suggest(date: date, hospital: "协和医院", doctor: "李医生", patientId: patient, candidates: [foreign, a]) == first)
        let tie = EncounterResolver.Candidate(id: second, patientId: patient, date: date, hospital: "北京协和医院", doctor: "李医生")
        #expect(EncounterResolver.suggest(date: date, hospital: "协和医院", doctor: "李医生", patientId: patient, candidates: [tie, a]) == nil)
        #expect(EncounterResolver.suggest(date: date, hospital: "另一家医院", doctor: "李医生", patientId: patient, candidates: [a]) == nil)
    }

    @Test func 明确不关联与未选择可分别往返() throws {
        let explicit = EncounterAssociation.none
        let data = try JSONEncoder().encode(explicit)
        #expect(try JSONDecoder().decode(EncounterAssociation.self, from: data) == .none)
        #expect(explicit != .unselected)
    }
}
