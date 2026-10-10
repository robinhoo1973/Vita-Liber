import Foundation

/// 首页快速拍摄入口的四类意图（record/report/prescription/symptom）。
/// 原随 TodayStore 旧聚合投影同文件；收口批D（2026-10-10 死代码清退）删除该
/// 投影时本类型被误随文件删除——它是**活类型**（AppRoute.scanCapture 与
/// QuickCaptureView 仍在使用）。恢复定义为独立文件，语义零变化。
public enum CaptureKind: String, Sendable, Equatable, Codable, Hashable, CaseIterable, Identifiable {
    case record, report, prescription, symptom
    public var id: String { rawValue }
}
