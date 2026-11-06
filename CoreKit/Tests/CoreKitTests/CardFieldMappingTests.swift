import Testing
@testable import Domain

@Suite("Card field mapping")
struct CardFieldMappingTests {
    private func card(kind: String = "encounter") -> MatchedCard {
        MatchedCard(
            kind: kind, pageIndex: 0,
            shared: [
                FieldDraft(key: "hospital", value: "市一医院", confidence: 0.9),
                FieldDraft(key: "doctor", value: "王医生", confidence: 0.9),
            ],
            rows: [
                MatchedCardRow(fields: [
                    FieldDraft(key: "drug_name", value: "阿莫西林", confidence: 0.9),
                    FieldDraft(key: "dosage", value: "0.5g", confidence: 0.9),
                ])
            ],
            allFieldCoverage: 1, requiredCoverage: 1,
            missingRequired: [], level: .complete)
    }

    @Test("options include current but exclude occupied and internal keys")
    func optionsFilterOccupied() {
        let options = CardFieldMapping.options(
            kind: "encounter", present: ["hospital", "doctor", "date"],
            rowLevel: false, currentKey: "hospital")
        #expect(options.contains { $0.key == "hospital" })
        #expect(!options.contains { $0.key == "doctor" })
        #expect(!options.contains { $0.key == "metric_key" })
        #expect(options.contains { $0.key == "department" })

        // 共享面不得把行级键（drug_name）当表头字段改名目标。
        let prescription = CardFieldMapping.options(
            kind: "prescription", present: ["hospital"], rowLevel: false, currentKey: "hospital")
        #expect(!prescription.contains { $0.key == "drug_name" })
        #expect(prescription.contains { $0.key == "prescribed_at" })
    }

    @Test("options are empty for an unknown card kind")
    func unknownKindHasNoOptions() {
        #expect(CardFieldMapping.options(kind: "not_a_card", present: [],
                                         rowLevel: false, currentKey: "x").isEmpty)
    }

    @Test("rename rejects duplicate target and preserves value/anchor")
    func renameRejectsDuplicate() {
        var c = card()
        let ok = CardFieldMapping.rename(in: &c, rowID: nil, index: 0, to: "doctor")
        #expect(!ok)
        #expect(c.shared[0].key == "hospital")

        let moved = CardFieldMapping.rename(in: &c, rowID: nil, index: 0, to: "department")
        #expect(moved)
        #expect(c.shared[0].key == "department")
        #expect(c.shared[0].value == "市一医院")
    }

    @Test("rename invalidates a previous confirmation")
    func renameInvalidatesConfirmation() {
        var c = card()
        c.shared[0].confirm()
        #expect(c.shared[0].isConfirmed)
        let ok = CardFieldMapping.rename(in: &c, rowID: nil, index: 0, to: "department")
        #expect(ok)
        #expect(!c.shared[0].isConfirmed)
    }

    @Test("row rename uses row-level catalog and keeps row identity")
    func rowRename() {
        var c = card(kind: "prescription")
        let rowID = c.rows[0].id
        let ok = CardFieldMapping.rename(in: &c, rowID: rowID, index: 1, to: "frequency")
        #expect(ok)
        #expect(c.rows[0].id == rowID)
        #expect(c.rows[0].fields[1].key == "frequency")
        #expect(c.rows[0].fields[1].value == "0.5g")
    }

    @Test("rename never resurrects a rejected field")
    func renameRejectsRejectedField() {
        var c = card()
        c.shared[0].reject()
        let ok = CardFieldMapping.rename(in: &c, rowID: nil, index: 0, to: "department")
        #expect(!ok)
        #expect(c.shared[0].key == "hospital")
        #expect(c.shared[0].grade == .rejected)
    }
}
