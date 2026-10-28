import Foundation

/// 患者主库文件名全集与解析规则（B0 转换登记表批，2026-10-29）。
///
/// 只认规范名会让「旧名存活」被当成全新安装而静默建空库（SRE 席失败面②）。
/// 解析必须基于「目录实况 × 注册名全集」，且 ≥2 候选一律 fail-closed——
/// 绝不按 mtime/大小猜测哪份是用户最新档案（BR-002 原件不动，此处同理）。
/// 本文件是纯规则（Domain）；文件系统扫描在 Infrastructure（PatientDatabaseLocator）。
public enum PatientDatabaseNames {
    /// 规范名（三段落命名规范，2026-10-25；vitaliber.sqlite 迁出后）。
    public static let canonical = "app-local-user_data.sqlite"
    /// 历史名（2026-10-25 前装机）。启动解析单命中时封 WAL 后原子改名为规范名。
    public static let legacy = "vitaliber.sqlite"
    /// 注册名全集：路径解析、L0 对账与备份恢复识别共用这一份，不得手写第二份。
    public static let all: [String] = [canonical, legacy]

    /// 大小写折叠命中（大小写不敏感卷上 "VITALIBER.sqlite" 即同一注册名）。
    public static func isRegistered(_ name: String) -> Bool {
        all.contains { $0.lowercased() == name.lowercased() }
    }
}

/// 目录实况 → 解析结论（纯函数：调用方传入目录里实际存在的文件名）。
public enum DatabaseNameResolution: Equatable, Sendable {
    /// 目录中没有注册名文件：全新安装（是否「丢库」由原件证据另判，见启动门探测）。
    case missing
    /// 恰一个候选：关联值为磁盘上的实际文件名（大小写可能与注册名不同）。
    case single(String)
    /// ≥2 候选并存：不猜、不合并、不删除——启动门进入可解释失败态，
    /// 由用户人工核对保留哪份（对应旧 `removeLegacyDatabaseIfNeeded` 只告警的缺口）。
    case ambiguous([String])

    /// 命中注册名全集的候选 → 结论。排序取 lowercased 字典序，日志/收据/断言稳定。
    public static func decide(presentNames: [String]) -> DatabaseNameResolution {
        let registered = presentNames
            .filter(PatientDatabaseNames.isRegistered)
            .sorted { $0.lowercased() < $1.lowercased() }
        switch registered.count {
        case 0: return .missing
        case 1: return .single(registered[0])
        default: return .ambiguous(registered)
        }
    }
}
