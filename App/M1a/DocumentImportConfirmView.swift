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
    /// FR6.9 跳过稍后确认对话框（部分完整才可入口；严重缺失不建卡退回原文）
    @State private var showSkipDialog = false
    /// 保存结果单一告警入口（审查修复：多 alert 挂同层视图节点时 SwiftUI
    /// 只呈现最后一个——保存失败/处方未同步/健康问题入口统一为枚举单 alert）
    @State private var activeAlert: ConfirmAlert?
    enum ConfirmAlert: String, Identifiable {
        case saveFailed
        /// 主文档已保存、处方副表同步失败的非阻断告警（处方行失败不得回滚
        /// 主记录，但也不能像此前 try? 吞错那样按成功静默 dismiss）
        case prescriptionWarning
        /// FR11.4：病历类文档保存成功后提供「创建健康问题」入口
        case healthProblemOffer
        var id: String { rawValue }
    }

    /// FR6.9 完整度评估（Domain 纯函数，data-flow §17 单一事实源）：
    /// 处方路径经标签身份归一稳定键；其余文档按 document_file 口径
    /// （仅 doc_type 必填——期一无类型化卡片字段，恒完整，不提供跳过）。
    private var completeness: CompletenessAssessment {
        if draft.isPrescription {
            return CompletenessEvaluator.assess(
                fields: CompletenessEvaluator.prescriptionFieldDrafts(
                    fields: draft.confirmationSet.fields,
                    labels: DocumentsState.prescriptionLabels),
                cardKind: "prescription")
        }
        return CompletenessEvaluator.assess(
            fields: draft.confirmationSet.fields.map {
                FieldDraft(key: $0.key, value: $0.value, confidence: $0.confidence)
            },
            cardKind: "document_file")
    }

    /// 缺失字段的展示标签（跳过确认对话框列出）。
    private var missingFieldLabels: [String] {
        completeness.missingFields.map { DocumentsState.fieldLabel(forKey: $0.key) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !draft.qualityTags.isEmpty {
                    Section {
                        ForEach(draft.qualityTags, id: \.self) { tag in
                            Label(L10n.qualityTag(tag), systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                // 语义令牌替代系统原色（第四轮全仓审查修复）
                                .foregroundStyle(Color("semantic-warning", bundle: .main))
                        }
                    }
                }
                // V3.41 文档类型后置判定（第八轮全仓审查修复）：类型不再是
                // 导入前静默定死的标签——确认卡以 D 级草稿呈现当前判定
                // （入口 hint/手动指定），可一键改（FR5.5 覆盖语义；FR17.18
                // 共享理解层期一落地后判定建议由此处汇入）。可选项 = 内置
                // 标签 + 当前自定义值（防自定义标签不在内置清单时 Picker
                // 无匹配 tag）。
                Section {
                    HStack {
                        Text(L10n.docConfirmDocType).font(.subheadline)
                        Spacer()
                        GradeBadge(grade: "D")
                    }
                    Picker(L10n.docConfirmDocType, selection: $draft.docType) {
                        let options = L10n.docTypeLabels.contains(draft.docType)
                            ? L10n.docTypeLabels
                            : L10n.docTypeLabels + [draft.docType]
                        ForEach(options, id: \.self) { label in
                            Text(label).tag(label)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("SP-11.docConfirm.docType")
                } footer: {
                    Text(L10n.docConfirmDocTypeHint)
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
                        // 4.28 OcrFieldGroupCard 信息卡分组（V3.49）：字段按
                        // 判定类别分组为多卡（卡头=类别+D 徽章+卡级确认），
                        // 未匹配字段进「未分类」卡兜底——不阻塞确认
                        ForEach(fieldGroups(), id: \.category) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(L10n.ocGroupName(group.category))
                                        .font(.subheadline.bold())
                                    GradeBadge(grade: "D")
                                    Spacer()
                                    Button(L10n.ocConfirmCardAll) {
                                        confirmCard(group.indices)
                                    }
                                    .font(.caption)
                                    .disabled(cardHasLowConfidence(group.indices))
                                    .accessibilityIdentifier("SP-11.docConfirm.cardAll.\(group.category)")
                                }
                                ForEach(group.indices, id: \.self) { idx in
                                    FieldConfirmRow(field: $draft.confirmationSet.fields[idx])
                                }
                            }
                            .padding(.vertical, 4)
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
                // FR6.9 跳过稍后出口：仅部分完整可暂存待办卡（§17.3 对照表）；
                // 严重缺失不建卡、识别文本退回原始记录（无此按钮，用户取消即
                // 放弃本卡——原文保留在 document 流程外，不产生任何实体）。
                if completeness.level == .partiallyComplete && docs.canSkipForLater {
                    Section {
                        Button {
                            showSkipDialog = true
                        } label: {
                            Label(L10n.docConfirmSkipLater, systemImage: "clock.badge.checkmark")
                        }
                        .accessibilityIdentifier("SP-12.skip-later")
                    } footer: {
                        Text(L10n.docConfirmSkipTitle)
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
        }
        // 单一告警入口：多 alert 不得挂同一视图节点（SwiftUI 只呈现最后一个）
        .alert(
            activeAlert == .saveFailed ? L10n.docConfirmSaveFailedTitle
                : activeAlert == .prescriptionWarning ? L10n.homeCaptureSaved
                : L10n.healthProblemOfferTitle,
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { activeAlert = nil } })
        ) {
            switch activeAlert {
            case .saveFailed:
                Button(L10n.onboard_gotIt, role: .cancel) { }
            case .prescriptionWarning:
                Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
            case .healthProblemOffer:
                Button(L10n.healthProblemCreate) {
                    createHealthProblem()
                }
                Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
            case nil:
                EmptyView()
            }
        } message: {
            switch activeAlert {
            case .saveFailed:
                Text(docs.lastImportError ?? L10n.docImportFailed)
            case .prescriptionWarning:
                Text(L10n.docPrescriptionSyncFailed)
            case .healthProblemOffer:
                Text(L10n.healthProblemOfferBody)
            case nil:
                EmptyView()
            }
        }
        // FR6.9 §18.4 交互契约：确认卡「跳过稍后」→ 列出缺失字段 → 用户确认
        // 才建卡；取消 = 丢弃本次识别（不创建任何实体）
        .confirmationDialog(L10n.docConfirmSkipTitle, isPresented: $showSkipDialog,
                            titleVisibility: .visible) {
            Button(L10n.docConfirmSkipConfirm) {
                skipForLater()
            }
            Button(L10n.docConfirmSkipCancel, role: .cancel) { }
        } message: {
            Text(missingFieldLabels.joined(separator: "、"))
        }
    }

    /// FR6.9 跳过稍后执行：写 pending_card（D 级草稿）后 dismiss。
    /// 写入失败必须可见（§7 不静默吞），不得按「已保存」关闭。
    private func skipForLater() {
        Task {
            let saved = await docs.skipForLater(draft: draft, assessment: completeness)
            if saved {
                dismiss()
            } else {
                activeAlert = .saveFailed
            }
        }
    }

    /// 4.28 信息卡分组：字段键 → 类别键（Domain FieldGroupRules 单一事实源），
    /// 卡序固定 rx → lab → visit → generic；索引保持确认集原序（绑定寻址）。
    private func fieldGroups() -> [(category: String, indices: [Int])] {
        var map: [String: [Int]] = [:]
        for (idx, field) in draft.confirmationSet.fields.enumerated() {
            map[FieldGroupRules.category(ofKey: field.key), default: []].append(idx)
        }
        return FieldGroupRules.categoryOrder.compactMap { key in
            map[key].map { (category: key, indices: $0) }
        }
    }

    /// 卡级确认（4.28）：确认本卡全部未确认字段——低置信闸门与页面级同语义
    /// （卡内有未确认低置信字段时按钮已禁用，此处不再代位复核）
    private func confirmCard(_ indices: [Int]) {
        for idx in indices {
            _ = draft.confirmationSet.fields[idx].confirm()
        }
    }

    private func cardHasLowConfidence(_ indices: [Int]) -> Bool {
        indices.contains { idx in
            let field = draft.confirmationSet.fields[idx]
            return field.grade == .ocrUnconfirmed && ConfidenceTier.tier(field.confidence) == .low
        }
    }

    /// FR11.4 懒创建：候选名由 Domain 纯函数派生（诊断字段优先），
    /// 用户确认后经 DocumentsState 落 health_problem。成功才收卡；
    /// 失败必须可见（§7 不静默吞——此前 Bool 结果被丢弃、无条件 dismiss，
    /// 用户以为已创建，时间轴里却没有条目）
    private func createHealthProblem() {
        let name = HealthProblemDerivation.candidateName(
            fields: draft.confirmationSet.confirmedFields, docTypeLabel: draft.docType)
        Task {
            let created = await docs.createHealthProblem(patientId: draft.patientId, name: name)
            if created {
                dismiss()
            } else {
                activeAlert = .saveFailed
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
                activeAlert = .saveFailed
            } else if docs.prescriptionSyncFailed {
                // 主文档已保存（成功语义），处方副表失败单独提示——
                // 不阻断 dismiss（主记录在库），但用户必须知道处方未同步
                activeAlert = .prescriptionWarning
            } else if docs.isClinicalDocType(draft.docType) {
                // FR11.4 懒创建触发（V3.49）：病历类文档保存成功 →
                // 「创建健康问题」入口（候选名 Domain 派生、用户确认落库）。
                // 按**保存时** docType 判定——确认卡 Picker 改类后判定随之
                // 更新（此前读 buildDraft 冻结的 isClinicalType 快照：
                // 改离病历类仍弹入口 / 改入病历类反而不弹）
                activeAlert = .healthProblemOffer
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
