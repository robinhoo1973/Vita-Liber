import SwiftUI
import UIKit
import Domain
import Infrastructure

/// FR6.1 拍摄/选取导入的确认卡（此前 `DocumentsState.importImage` 直接以 D 级
/// 静默入库，全程无用户确认环节——本视图补齐 BR-003「机器识别字段必须逐条
/// 确认才生效」的产品要求）：展示矫正后的扫描区域图 + 逐条候选字段，用户
/// 确认/改正每一项后才写入数据库。处方类文档（docType=处方单）字段带处方
/// 语义标签（药品名/剂量/频次/医院/医生，见 `PrescriptionFieldMapper`），
/// 确认后额外落一条 `prescription` 记录（`DocumentsState.commitDraft`）。
struct DocumentImportConfirmView: View {
    @Environment(DocumentsState.self) private var docs
    @Environment(\.dismiss) private var dismiss
    @State var draft: DocumentsState.ImportDraft
    @State private var showRegionImage = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                if !draft.qualityTags.isEmpty {
                    Section {
                        ForEach(draft.qualityTags, id: \.self) { tag in
                            Label(tag, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Button {
                        showRegionImage = true
                    } label: {
                        Label(L10n.docConfirmViewRegion, systemImage: "photo")
                    }
                    .accessibilityIdentifier("SP-11.docConfirm.viewRegion")
                } footer: {
                    Text(L10n.docConfirmHint)
                }
                Section {
                    if draft.confirmationSet.fields.isEmpty {
                        Text(ImageInputRules.noTextMessage).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach($draft.confirmationSet.fields) { $field in
                            FieldConfirmRow(field: $field)
                        }
                    }
                }
            }
            .navigationTitle(L10n.docConfirmTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                        .accessibilityIdentifier("SP-11.docConfirm.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.docConfirmSaveAll) {
                        confirmAllRemaining()
                        saving = true
                        Task {
                            await docs.commitDraft(draft)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("SP-11.docConfirm.saveAll")
                }
            }
            .sheet(isPresented: $showRegionImage) {
                if let image = UIImage(data: draft.processedData) {
                    NavigationStack {
                        Image(uiImage: image).resizable().scaledToFit().padding(12)
                            .navigationTitle(L10n.docConfirmViewRegion)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(L10n.onboard_gotIt) { showRegionImage = false }
                                }
                            }
                    }
                }
            }
        }
    }

    /// 「确认并保存」= 批量确认剩余未确认字段（用户已手动编辑过的值视为最终值）。
    private func confirmAllRemaining() {
        for i in draft.confirmationSet.fields.indices where draft.confirmationSet.fields[i].grade != .userConfirmed {
            _ = draft.confirmationSet.fields[i].confirm()
        }
    }
}

private struct FieldConfirmRow: View {
    @Binding var field: CandidateField
    @State private var editing = false
    @State private var draftValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.displayLabel).font(.caption).foregroundStyle(.secondary)
            if editing {
                TextField(field.displayLabel, text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L10n.onboard_saveEdit) {
                        _ = field.revise(to: draftValue)
                        _ = field.confirm()
                        editing = false
                    }
                    Button(L10n.onboard_cancel, role: .cancel) { editing = false }
                }
                .font(.caption)
            } else {
                Text(field.value).font(.body)
                HStack(spacing: 12) {
                    Text(field.isConfirmed ? L10n.onboard_confirmed : L10n.onboard_unconfirmedBadge)
                        .font(.caption2)
                        .foregroundStyle(field.isConfirmed ? Color("grade-c", bundle: .main) : Color("grade-d", bundle: .main))
                    if !field.isConfirmed {
                        Button(L10n.onboard_revise) {
                            draftValue = field.value
                            editing = true
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("SP-11.docConfirm.field.\(field.key)")
    }
}
