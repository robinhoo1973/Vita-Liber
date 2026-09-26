import SwiftUI
import Domain

/// 待办卡部分已填数据的只读呈现（字典回退形态）：共享字段 + 多行，
/// `metric_key` 不渲染。2026-09-26 审查修复：此前同一 13 行渲染块在
/// `PendingCardResumeRouteView`（来源缺失只读快照）与首页
/// `PendingCardDetailSheet.detailSections`（无 card 快照回退）两处逐字复制——
/// 字段过滤/排序/展示规则的任何改动都要改两遍，必然漂移。单一出口。
struct PendingCardPartialDataSection: View {
    let payload: PendingCardPayload

    var body: some View {
        ForEach(payload.shared.filter { $0.key != "metric_key" }.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
            LabeledContent(DocumentsDisplay.fieldLabel(forKey: key),
                           value: DocumentsDisplay.fieldValueDisplay(forKey: key, value: value))
        }
        ForEach(Array(payload.rows.enumerated()), id: \.offset) { index, row in
            VStack(alignment: .leading) {
                Text(L10n.entityCardRowIndex(index + 1)).font(.caption)
                ForEach(row.filter { $0.key != "metric_key" }.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    LabeledContent(DocumentsDisplay.fieldLabel(forKey: key),
                                   value: DocumentsDisplay.fieldValueDisplay(forKey: key, value: value))
                }
            }
        }
    }
}
