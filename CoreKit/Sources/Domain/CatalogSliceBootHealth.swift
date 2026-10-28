import Foundation

/// 切片启动健康度（U-批 B2，2026-10-28；typed 枚举，取代 `label=="ready"` 字符串判定）。
///
/// 映射来源 = `CatalogSliceProbe.inspectSelfConsistent`（Q14=B 后维持**全量校验**：
/// 表集 + slice_meta 契约 + integrity_check + foreign_key_check + 逐表 COUNT）。
/// 本枚举是启动门/自检行/诊断的唯一健康语义；`rawValue` 仅供诊断字符串输出。
public enum CatalogSliceBootHealth: String, Sendable, Equatable, CaseIterable {
    /// 全验通过（可挂读面）。
    case ready
    /// 文件不存在（可选片常态；必需片缺失→首启卡）。
    case missing
    /// 文件存在但打不开（IO/锁/非 SQLite）。
    case unreadable
    /// `slice_meta` 契约违反（缺键/重复键/坏值/表集或计数与声明不符）。
    case contractViolation = "contract-violation"
    /// 物理表集与 manifest 不符（多表/少表/混入 catalog_meta 等）。
    case tableSetMismatch = "table-set-mismatch"
    /// `PRAGMA integrity_check` 失败。
    case integrityFailed = "integrity-failed"
    /// 逐表 COUNT 与 slice_meta 声明不符。
    case countsMismatch = "counts-mismatch"

    /// 诊断字符串（与旧 `sliceLabel` 输出逐字一致，保证日志/测试兼容）。
    public var diagnosticLabel: String { rawValue }
}
