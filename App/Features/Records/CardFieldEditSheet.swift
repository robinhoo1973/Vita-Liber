import SwiftUI
import Domain
import Infrastructure
import Perception

/// 已确认卡字段编辑（业主 2026-09-20 第 4 项：保存后从健康档案进入相关字段编辑）。
///
/// 语义纪律（与 `OCRCardStore.updateCardFields` 同源）：
/// - 编辑即确认——用户从档案入口显式更正，保存后事实列直接更新（confirmed 不变）；
/// - 只改值、不动身——回执/来源页/原件（BR-002）不受影响，审计 JSON 随更正同步；
/// - 清空 = 不改（期二登记：清空语义需回执手术）。
/// - 日期/数值在保存前按 `EntityCardProjection.parseDate` / Double 同口径预校验，
///   失败给行内错误，不让 store 抛裸错。
@MainActor
struct CardFieldEditSheet: View {
    let kind: String
    let entityId: UUID
    let patientId: UUID
    let detail: OCRCardStore.CardDetail
    let onSaved: () -> Void

    @Environment(DocumentsState.self) private var docs
    @Environment(\.dismiss) private var dismiss

    @State private var fields: [FieldDraft] = []
    @State private var lines: [PrescriptionLine] = []
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var saved = false

    private static let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    Section {
                        Text(L10n.cardEditHint)
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(fields.indices, id: \.self) { index in
                            editRow(fields[index])
                        }
                    } header: {
                        Text(L10n.cardEditFieldsSection)
                    }
                    if kind == "prescription" {
                        ForEach(lines.indices, id: \.self) { index in
                            prescriptionLineSection(index)
                        }
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage).font(.caption)
                                .foregroundStyle(Color("semantic-danger", bundle: .main))
                        }
                    }
                }
                .navigationTitle(L10n.cardEditTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonCancel) { dismiss() }.disabled(saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.cardEditSave) { save() }
                            .disabled(saving || saved)
                            .accessibilityIdentifier("cardEdit.save")
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .task { prepare() }
            .alert(L10n.cardEditSaved, isPresented: $saved) {
                Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
            } message: { Text(L10n.cardEditSavedHint) }
        }
    }

    private func prepare() {
        fields = detail.fields
        lines = detail.lines
    }

    @ViewBuilder
    private func editRow(_ field: FieldDraft) -> some View {
        let key = field.key
        if let options = DocumentsDisplay.enumOptions(forKey: key), !options.isEmpty {
            Picker(DocumentsDisplay.fieldLabel(forKey: key), selection: valueBinding(key)) {
                if !options.contains(field.value) && !field.value.isEmpty {
                    Text(field.value).tag(field.value)
                }
                ForEach(options, id: \.self) { option in
                    Text(DocumentsDisplay.fieldValueDisplay(forKey: key, value: option)).tag(option)
                }
            }
        } else {
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: key)) {
                TextField("", text: valueBinding(key), axis: .vertical)
                    .lineLimit(1...4)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func valueBinding(_ key: String) -> Binding<String> {
        Binding(get: {
            fields.first { $0.key == key }?.value ?? ""
        }, set: { value in
            if let index = fields.firstIndex(where: { $0.key == key }) {
                fields[index].value = value
            }
        })
    }

    @ViewBuilder
    private func prescriptionLineSection(_ index: Int) -> some View {
        let line = lines[index]
        let title = line.printedName.isEmpty ? L10n.entityCardRowIndex(index + 1) : line.printedName
        Section {
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: "drug_name")) {
                TextField("", text: lineTextBinding(index, { $0.printedName }, { $0.printedName = $1 }))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: "spec")) {
                TextField("", text: lineTextBinding(index, { $0.spec ?? "" }, { $0.spec = $1.isEmpty ? nil : $1 }))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: "dosage")) {
                HStack(spacing: 6) {
                    TextField("", text: lineTextBinding(index, { $0.doseText ?? "" }, { $0.doseText = $1.isEmpty ? nil : $1 }))
                        .multilineTextAlignment(.trailing)
                    TextField("", text: lineTextBinding(index, { $0.doseUnit ?? "" }, { $0.doseUnit = $1.isEmpty ? nil : $1 }))
                        .frame(maxWidth: 72).multilineTextAlignment(.trailing)
                }
            }
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: "frequency")) {
                TextField("", text: lineTextBinding(index, { $0.frequencyText ?? "" }, { $0.frequencyText = $1.isEmpty ? nil : $1 }))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: "days")) {
                TextField("", text: lineTextBinding(index, { $0.durationText ?? "" }, { $0.durationText = $1.isEmpty ? nil : $1 }))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: "note")) {
                TextField("", text: lineTextBinding(index, { $0.note ?? "" }, { $0.note = $1.isEmpty ? nil : $1 }))
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text(L10n.cardEditLineTitle(title))
        }
    }

    /// 处方行文本列绑定（String 与 String? 列同一出口；空串回写 nil，与事实列空值形态同口径）。
    private func lineTextBinding(_ index: Int,
                                 _ get: @escaping (PrescriptionLine) -> String,
                                 _ set: @escaping (inout PrescriptionLine, String) -> Void) -> Binding<String> {
        Binding(get: {
            guard lines.indices.contains(index) else { return "" }
            return get(lines[index])
        }, set: { value in
            guard lines.indices.contains(index) else { return }
            set(&lines[index], value)
        })
    }

    private func save() {
        guard let store = docs.cardStore, !saving else { return }
        // 保存前预校验（与 store 同口径）：日期 yyyy-MM-dd；数值 Double
        let dateKeys: Set<String> = ["administered_at", "diagnosed_at", "exam_at", "reported_at",
                                     "surgery_at", "ended_at", "treated_at",
                                     "admit_at", "discharge_at", "summary_date"]
        let numericKeys: Set<String> = ["amount", "reimbursed_amount", "out_of_pocket",
                                        "personal_account_amount", "total_amount", "total_cost",
                                        "value", "ref_low", "ref_high", "unit_price", "line_amount"]
        for field in fields {
            let text = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if dateKeys.contains(field.key), EntityCardProjection.parseDate(text, calendar: Self.calendar) == nil {
                errorMessage = L10n.cardEditInvalidDate(DocumentsDisplay.fieldLabel(forKey: field.key))
                return
            }
            if numericKeys.contains(field.key), Double(text) == nil {
                errorMessage = L10n.cardEditInvalidNumber(DocumentsDisplay.fieldLabel(forKey: field.key))
                return
            }
        }
        errorMessage = nil
        saving = true
        let snapshotFields = fields
        let snapshotLines = lines
        Task {
            defer { saving = false }
            do {
                try await store.updateCardFields(kind: kind, entityId: entityId, patientId: patientId,
                                                 shared: snapshotFields, lines: snapshotLines)
                saved = true
                onSaved()
            } catch {
                errorMessage = L10n.cardEditFailed
            }
        }
    }
}
