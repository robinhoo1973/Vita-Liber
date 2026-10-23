import Foundation
import Testing
import Domain

/// SU-M2-ARCHIVE-SCOPE：FR11.2 V4.05——Apple 健康导入（`.healthData`）不入健康档案；
/// 2026-10-23 起医疗档案（`.healthProblem`）同样只在「医疗档案」总览展示。
/// 单一事实源 `TimelineEntryKind.recordsArchiveKinds` / `appearsInRecordsArchive` 的目录断言。
@Suite("SU-M2-ARCHIVE-SCOPE FR11.2 设备与医疗档案数据不入健康档案")
struct TimelineArchiveVisibilityTests {

    private static let excluded: Set<TimelineEntryKind> = [.healthData, .healthProblem]

    @Test("recordsArchiveKinds = 全目录 − healthData − healthProblem")
    func archiveKindsExcludeNonRecords() {
        let archive = TimelineEntryKind.recordsArchiveKinds
        #expect(!archive.contains(.healthData), "Apple 健康导入专属「健康数据」tab")
        #expect(!archive.contains(.healthProblem), "慢性病/手术史归「医疗档案」总览")
        #expect(archive.count == TimelineEntryKind.allCases.count - Self.excluded.count)
        #expect(archive == TimelineEntryKind.allCases.filter { !Self.excluded.contains($0) }, "顺序稳定（目录序）")
    }

    @Test("appearsInRecordsArchive：仅 healthData/healthProblem 为 false")
    func onlyNonRecordsExcluded() {
        for kind in TimelineEntryKind.allCases {
            #expect(kind.appearsInRecordsArchive == !Self.excluded.contains(kind), "\(kind.rawValue)")
        }
        #expect(TimelineEntryKind.selfMeasured.appearsInRecordsArchive)
        #expect(TimelineEntryKind.lab.appearsInRecordsArchive)
        #expect(TimelineEntryKind.observation.appearsInRecordsArchive)
    }
}
