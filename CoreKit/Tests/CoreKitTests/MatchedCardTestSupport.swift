import Foundation
@testable import Domain

extension MatchedCard {
    /// 「用户已完成确认」态：**批量确认可选字段 + 逐项确认全部必填字段**。
    ///
    /// **为什么需要它**（2026-09-17 判据改版，业主定「信息卡中的必要字段必须逐一确认」）：
    /// `confirmingAllFields()` 不再升必填字段——故它单独**产不出可保存的卡**
    /// （`invalidFields` 会把「非空但未确认」的必填字段判无效，这正是强制逐一确认的机制）。
    ///
    /// 本助手补上第二步，与 UI 现在必须走的两步流程同构：
    /// ① [确认保存] 批量确认可选字段 → ② 必填字段逐个确认。
    ///
    /// 测试要构造「可保存卡」时应使用本助手，而非裸 `confirmingAllFields()`。
    func fullyConfirmed() -> MatchedCard {
        var out = confirmingAllFields()
        let entry = CardKindRegistry.entry(for: out.kind)
        for index in out.shared.indices where (entry?.sharedRequired ?? []).contains(out.shared[index].key) {
            _ = out.shared[index].confirm()
        }
        for rowIndex in out.rows.indices {
            // 空行 = 「表头即实体」：不受行级必填约束（与 `invalidFields` 同口径）
            let required = (entry?.allowsEmptyRows == true && out.rows[rowIndex].fields.isEmpty)
                ? [] : (entry?.rowRequired ?? [])
            for fieldIndex in out.rows[rowIndex].fields.indices
            where required.contains(out.rows[rowIndex].fields[fieldIndex].key) {
                _ = out.rows[rowIndex].fields[fieldIndex].confirm()
            }
        }
        return out
    }
}
