import Foundation
import Testing
@testable import Domain

@Suite("Card action attribution")
struct CardActionTests {
    private let patient = UUID()
    private let other = UUID()
    private let encounter = UUID()
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }
    private func day(_ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour)) ?? Date()
    }
    private func orphan(kind: String = "prescription", documentTypeKey: String = "prescription",
                        entityId: UUID? = UUID(), date: Date? = nil,
                        hospital: String? = "市第一医院", department: String? = "心内科",
                        doctor: String? = "王医生", current: UUID? = nil) -> OrphanCard {
        OrphanCard(patientId: patient, kind: kind, documentTypeKey: documentTypeKey,
                   entityId: entityId, documentSha256: "sha", pageIndex: 0, rowAnchor: "r1",
                   date: date ?? day(5), hospital: hospital,
                   department: department, doctor: doctor, currentEncounterId: current)
    }
    private func candidate(id: UUID = UUID(), patientId: UUID? = nil, kind: String = "outpatient",
                           date: Date? = nil, hospital: String = "市第一医院",
                           department: String? = "心内科", doctor: String? = "王医生",
                           stayStart: Date? = nil, stayEnd: Date? = nil) -> EncounterCandidate {
        EncounterCandidate(id: id, patientId: patientId ?? patient, date: date ?? day(5),
                           kind: kind, hospital: hospital, department: department, doctor: doctor,
                           stayStart: stayStart, stayEnd: stayEnd)
    }

    @Test("inpatient stay uses closed episode window, not ±3 days")
    func inpatientEpisodeWindow() {
        let ip = candidate(kind: "inpatient", date: day(1),
                           stayStart: day(1), stayEnd: day(10))
        let out = AttributionPlanner.plan(patientId: patient,
                                          orphans: [orphan(date: day(7))],
                                          encounters: [ip], now: day(12), calendar: calendar)
        #expect(out.count == 1)
        #expect(out[0].encounterId == ip.id)
    }

    @Test("discharged report outside stay is not attributed")
    func afterDischargeRejected() {
        let ip = candidate(kind: "inpatient", date: day(1),
                           stayStart: day(1), stayEnd: day(10))
        let out = AttributionPlanner.plan(patientId: patient,
                                          orphans: [orphan(date: day(12))],
                                          encounters: [ip], now: day(15), calendar: calendar)
        #expect(out.isEmpty)
    }

    @Test("generic hospital needs department and doctor corroboration")
    func genericHospitalNeedsSecondSignal() {
        let c = candidate(hospital: "人民医院", department: nil, doctor: nil)
        let weak = AttributionPlanner.plan(patientId: patient,
                                           orphans: [orphan(hospital: "人民医院",
                                                            department: nil, doctor: nil)],
                                           encounters: [c], now: day(20), calendar: calendar)
        #expect(weak.isEmpty)
        let strong = AttributionPlanner.plan(patientId: patient,
                                             orphans: [orphan(hospital: "人民医院",
                                                              department: "心内科", doctor: "王医生")],
                                             encounters: [candidate(hospital: "人民医院")],
                                             now: day(20), calendar: calendar)
        #expect(strong.count == 1)
    }

    @Test("multiple equal candidates withhold")
    func tieWithheld() {
        let a = candidate()
        let b = candidate()
        let out = AttributionPlanner.plan(patientId: patient, orphans: [orphan()],
                                          encounters: [a, b], now: day(20), calendar: calendar)
        #expect(out.isEmpty)
    }

    @Test("cross-member / cross-hospital / existing parent / pending entity withheld")
    func hardWithholds() {
        #expect(AttributionPlanner.plan(
            patientId: patient, orphans: [orphan()],
            encounters: [candidate(patientId: other)],
            now: day(20), calendar: calendar).isEmpty)
        #expect(AttributionPlanner.plan(
            patientId: patient, orphans: [orphan(hospital: "市第二医院")],
            encounters: [candidate()], now: day(20), calendar: calendar).isEmpty)
        #expect(AttributionPlanner.plan(
            patientId: patient, orphans: [orphan(current: encounter)],
            encounters: [candidate()], now: day(20), calendar: calendar).isEmpty)
        #expect(AttributionPlanner.plan(
            patientId: patient, orphans: [orphan(entityId: nil)],
            encounters: [candidate()], now: day(20), calendar: calendar).isEmpty)
    }

    @Test("lab metric_sample can attach; only checkup redirect is withheld")
    func labMetricSampleAllowed() {
        let out = AttributionPlanner.plan(
            patientId: patient,
            orphans: [orphan(kind: "metric_sample", documentTypeKey: "lab_report")],
            encounters: [candidate()], now: day(20), calendar: calendar)
        #expect(out.count == 1)
    }

    @Test("checkup child never falls back to encounter hub")
    func checkupWithheld() {
        let out = AttributionPlanner.plan(
            patientId: patient,
            orphans: [orphan(kind: "metric_sample", documentTypeKey: "checkup_report")],
            encounters: [candidate()], now: day(20), calendar: calendar)
        #expect(out.isEmpty)
    }

    @Test("key is stable for same evidence and changes with target evidence")
    func keyStability() {
        let a = CardActionKey(patientId: patient, action: .fixAttribution,
                              source: "doc:sha:0:r1", target: "encounter:1",
                              targetEvidence: "outpatient|市第一医院|1",
                              evidence: "hospital=市第一医院")
        let b = CardActionKey(patientId: patient, action: .fixAttribution,
                              source: "doc:sha:0:r1", target: "encounter:1",
                              targetEvidence: "outpatient|市第一医院|1",
                              evidence: "hospital=市第一医院")
        let c = CardActionKey(patientId: patient, action: .fixAttribution,
                              source: "doc:sha:0:r1", target: "encounter:1",
                              targetEvidence: "outpatient|市第一医院|2",
                              evidence: "hospital=市第一医院")
        #expect(a == b)
        #expect(a != c)
    }
}
