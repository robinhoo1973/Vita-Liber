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
                        // round5 Q1（F1.4）：后期补填——目录（CardKindRegistry 共享面可选键）− 已有键；
                        // 此前编辑面只列 detail.fields（有值字段），OCR 漏抽的字段在档案里永远补不上。
                        addFieldMenu
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
        // round5 Q4：控件按 Domain 单源 `valueKind` 选择（此前只有枚举 Picker / 文本框两分支）
        switch EntityCardProjection.valueKind(kind: kind, key: key) {
        case .enumerated(let options) where !options.isEmpty:
            Picker(DocumentsDisplay.fieldLabel(forKey: key), selection: valueBinding(key)) {
                if !options.contains(field.value) && !field.value.isEmpty {
                    Text(field.value).tag(field.value)
                }
                ForEach(options, id: \.self) { option in
                    Text(DocumentsDisplay.fieldValueDisplay(forKey: key, value: option)).tag(option)
                }
            }
        case .date:
            DateFieldEditor(label: DocumentsDisplay.fieldLabel(forKey: key), text: field.value) { valueBinding(key).wrappedValue = $0 }
        case .number, .integer:
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: key)) {
                TextField("", text: valueBinding(key))
                    .keyboardType(EntityCardProjection.valueKind(kind: kind, key: key) == .integer ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        default:
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: key)) {
                TextField("", text: valueBinding(key), axis: .vertical)
                    .lineLimit(1...4)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// 「添加字段」：共享面目录 − 已有键（目录与 SP-12 同源 `CardKindRegistry.optionalCatalog`）。
    @ViewBuilder
    private var addFieldMenu: some View {
        let catalog = CardKindRegistry.optionalCatalog(kind: kind, present: Set(fields.map(\.key)), rowLevel: false)
        if !catalog.isEmpty {
            Menu {
                ForEach(catalog, id: \.self) { key in
                    Button(DocumentsDisplay.fieldLabel(forKey: key)) {
                        guard !fields.contains(where: { $0.key == key }) else { return }
                        fields.append(FieldDraft(key: key, value: "", confidence: 1))
                    }
                }
            } label: {
                Label(L10n.cardEditAddField, systemImage: "plus.circle").frame(minHeight: 44)
            }
            .accessibilityIdentifier("cardEdit.addField")
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

    /// 处方行编辑：按 `PrescriptionLineField` 全列生成（round5 Q1 F1.4——此前手写 6 列，其余 13 列在档案里
    /// 不可编、不可补；`unit` 并入剂量行右侧小框；日期列走选择器、金额列数字键盘）。
    @ViewBuilder
    private func prescriptionLineSection(_ index: Int) -> some View {
        let line = lines[index]
        let title = line.printedName.isEmpty ? L10n.entityCardRowIndex(index + 1) : line.printedName
        Section {
            ForEach(PrescriptionLineField.allCases.filter { !$0.isUnitCompanion }, id: \.rawValue) { column in
                prescriptionLineRow(index, column)
            }
        } header: {
            Text(L10n.cardEditLineTitle(title))
        }
    }

    @ViewBuilder
    private func prescriptionLineRow(_ index: Int, _ column: PrescriptionLineField) -> some View {
        let label = DocumentsDisplay.fieldLabel(forKey: column.key)
        switch column.valueKind {
        case .date:
            DateFieldEditor(label: label, text: lineColumnBinding(index, column).wrappedValue) { lineColumnBinding(index, column).wrappedValue = $0 }
        case .number, .integer:
            LabeledContent(label) {
                TextField("", text: lineColumnBinding(index, column))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
        default:
            LabeledContent(label) {
                HStack(spacing: 6) {
                    TextField("", text: lineColumnBinding(index, column)).multilineTextAlignment(.trailing)
                    if column == .dosage {
                        TextField(DocumentsDisplay.fieldLabel(forKey: PrescriptionLineField.unit.key), text: lineColumnBinding(index, .unit))
                            .frame(maxWidth: 72).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    /// 行列绑定单出口：读 `canonicalText`、写 `write(_:to:)`（空串 = 清空，与事实列 nil 同口径；不可解析保持原值）。
    private func lineColumnBinding(_ index: Int, _ column: PrescriptionLineField) -> Binding<String> {
        Binding(get: {
            guard lines.indices.contains(index) else { return "" }
            return column.canonicalText(of: lines[index], calendar: Self.calendar) ?? ""
        }, set: { value in
            guard lines.indices.contains(index) else { return }
            column.write(value, to: &lines[index], calendar: Self.calendar)
        })
    }

    private func save() {
        guard let store = docs.cardStore, !saving else { return }
        // 保存前预校验（与 store 同口径）：键型取 Domain 单源 `EntityCardProjection.valueKind`
        // （round5 Q4——此前本处手抄 dateKeys/numericKeys 两表，漏 fee_at/collected_at/start_date… 即退化为无校验文本）。
        for field in fields {
            let text = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch EntityCardProjection.valueKind(kind: kind, key: field.key) {
            case .date where EntityCardProjection.parseDate(text, calendar: Self.calendar) == nil:
                errorMessage = L10n.cardEditInvalidDate(DocumentsDisplay.fieldLabel(forKey: field.key))
                return
            case .number where Double(text) == nil, .integer where Int(text) == nil:
                errorMessage = L10n.cardEditInvalidNumber(DocumentsDisplay.fieldLabel(forKey: field.key))
                return
            default:
                break
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
