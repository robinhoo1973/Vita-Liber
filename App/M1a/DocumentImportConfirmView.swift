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
    @State private var showSaveError = false

    var body: some View {
        NavigationStack {
            List {
                if !draft.qualityTags.isEmpty {
                    Section {
                        ForEach(draft.qualityTags, id: \.self) { tag in
                            Label(tag, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                // 语义令牌替代系统原色（第四轮全仓审查修复）
                                .foregroundStyle(Color("semantic-warning", bundle: .main))
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
                        Text(L10n.imageInputNoText).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach($draft.confirmationSet.fields) { $field in
                            FieldConfirmRow(field: $field)
                        }
                        // §5.30 全部确认闸门（第四轮全仓审查修复：低置信度红色
                        // 字段存在时按钮禁用并给出原因——原实现无条件批量确认，
                        // 低置信误读值未经核对即升 C 进入事实链）
                        if !draft.confirmationSet.allConfirmAllowed {
                            Text(L10n.docConfirmAllConfirmBlocked)
                                .font(.caption)
                                .foregroundStyle(Color("semantic-danger", bundle: .main))
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
                        saveAll()
                    }
                    .disabled(saving || !draft.confirmationSet.allConfirmAllowed)
                    .accessibilityIdentifier("SP-11.docConfirm.saveAll")
                }
            }
            .sheet(isPresented: $showRegionImage) {
                regionPreview
            }
            .alert(L10n.docConfirmSaveFailedTitle, isPresented: $showSaveError) {
                Button(L10n.onboard_gotIt, role: .cancel) { }
            } message: {
                Text(docs.lastImportError ?? L10n.docImportFailed)
            }
        }
    }

    /// 矫正区域预览（第四轮全仓审查修复）：敏感草稿经 SensitiveMediaContainer
    /// 显式解锁才可见（BR-007 零解锁门直显断裂）；非敏感也走 ImageIO 降采样
    /// （§5.10 大图 OOM 纪律），不再全分辨率直显。
    private var regionPreview: some View {
        let downsampled = ImageIOImageLoader.downsample(data: draft.processedData, maxDimension: 2048)
        return NavigationStack {
            // 裸修饰符位于 ViewBuilder 内 if/else 之后会以 View 类型为基解析失败
            // （CI 34037986523 实证）——Group 包裹后修饰符挂在 Group 结果上
            Group {
                if draft.isSensitive {
                    SensitiveMediaContainer { _ in
                        Label(L10n.sensitiveMedia_unlockToView, systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    } content: { _ in
                        previewImage(downsampled)
                    }
                } else {
                    previewImage(downsampled)
                }
            }
            .navigationTitle(L10n.docConfirmViewRegion)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.onboard_gotIt) { showRegionImage = false }
                }
            }
        }
    }

    @ViewBuilder
    private func previewImage(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit().padding(12)
        }
    }

    /// 「确认并保存」= 批量确认剩余未确认字段（Domain confirmAllRemaining；
    /// 已拒绝字段不升格）。写库失败绝不 dismiss——失败必须可见（FR6.6），
    /// 用户逐条确认过的数据不因静默吞错而丢（第四轮全仓审查修复）。
    private func saveAll() {
        saving = true
        Task {
            draft.confirmationSet.confirmAllRemaining()
            await docs.commitDraft(draft)
            saving = false
            if docs.lastImportError != nil {
                showSaveError = true
            } else {
                dismiss()
            }
        }
    }
}

private struct FieldConfirmRow: View {
    @Binding var field: CandidateField
    @State private var editing = false
    @State private var draftValue = ""

    /// FR6.3 三级置信度（第四轮全仓审查修复：旧高绿/中黄/低红三级呈现随
    /// 向导简化删除后无重建 UI——低置信与高置信字段视觉无差别地被批量确认；
    /// 重建为语义令牌三档，未确认字段恒显示）
    private var tier: ConfidenceTier { ConfidenceTier.tier(field.confidence) }
    private var tierLabel: String {
        switch tier {
        case .high: return L10n.docConfirmConfidenceHigh
        case .mid: return L10n.docConfirmConfidenceMid
        case .low: return L10n.docConfirmConfidenceLow
        }
    }
    private var tierColor: Color {
        switch tier {
        case .high: return Color("semantic-success", bundle: .main)
        case .mid: return Color("semantic-warning", bundle: .main)
        case .low: return Color("semantic-danger", bundle: .main)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.displayLabel).font(.caption).foregroundStyle(.secondary)
                if !field.isConfirmed && field.grade != .rejected {
                    Text(tierLabel)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(tierColor.opacity(0.15)))
                        .foregroundStyle(tierColor)
                }
                Spacer()
                // GradeBadge 唯一渲染出口（第四轮全仓审查修复：原手写
                // C/D 状态色文本绕过设计系统组件）
                GradeBadge(grade: field.isConfirmed ? "C" : "D")
            }
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
                    if field.grade == .rejected {
                        // ✕ 放弃后的逆向操作（Domain reenable）
                        Button(L10n.docConfirmReenable) {
                            _ = field.reenable()
                        }
                        .font(.caption)
                    } else if !field.isConfirmed {
                        Button(L10n.onboard_revise) {
                            draftValue = field.value
                            editing = true
                        }
                        .font(.caption)
                        // FR6.4 ✕ 放弃（第四轮全仓审查修复：三操作之一随
                        // 旧确认视图删除后无重建点，用户被迫确认错误文本入库）
                        Button(L10n.docConfirmReject, role: .destructive) {
                            field.reject()
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
