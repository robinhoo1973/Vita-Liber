import SwiftUI

/// 排版/图标尺寸令牌（第八轮全仓审查修复）：
/// ui-ux-spec §3.2 正文字号标度止于 display 28——语音响度表、披露页、
/// 导出向导、首页快捷卡等处的**英雄图标/状态大字**超出标度，此前在
/// 视图内硬编码 `.font(.system(size: 40…56))`（§3.2「禁止硬编码字号」）。
/// 集中为本令牌表；新增超标度字号一律经本出口，标度扩展只改这里。
enum VLFont {
    /// 语音响度表主图标（44pt）
    static let levelDisplay: Font = .system(size: 44)
    /// 首页快捷操作大图标（40pt，配 64pt 触点）
    static let homeActionIcon: Font = .system(size: 40)
    /// 披露页信息大图标（48pt）
    static let disclosureIcon: Font = .system(size: 48)
    /// 导出向导完成态大图标（56pt）
    static let exportIcon: Font = .system(size: 56)
    /// 指标总览宫格大数字（§5.45；28pt bold rounded，硬编码字号收敛出口）
    static let metricTileValue: Font = .system(size: 28, weight: .bold, design: .rounded)
}
