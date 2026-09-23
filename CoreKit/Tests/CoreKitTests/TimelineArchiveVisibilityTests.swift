import Foundation
import Testing
import Domain

/// SU-M2-ARCHIVE-SCOPE：FR11.2 V4.05——Apple 健康导入（`.healthData`）不入健康档案。
/// 单一事实源 `TimelineEntryKind.recordsArchiveKinds` / `appearsInRecordsArchive` 的目录断言。
@Suite("SU-M2-ARCHIVE-SCOPE FR11.2 Apple 数据不入健康档案")
struct TimelineArchiveVisibilityTests {

    @Test("recordsArchiveKinds = 全目录 − healthData（且仅此一项被排除）")
    func archiveKindsExcludeOnlyHealthData() {
        let archive = TimelineEntryKind.recordsArchiveKinds
        #expect(!archive.contains(.healthData), "Apple 健康导入专属「健康数据」tab")
        #expect(archive.count == TimelineEntryKind.allCases.count - 1)
        #expect(archive == TimelineEntryKind.allCases.filter { $0 != .healthData }, "顺序稳定（目录序）")
    }

    @Test("appearsInRecordsArchive：仅 healthData 为 false")
    func onlyHealthDataExcluded() {
        for kind in TimelineEntryKind.allCases {
            #expect(kind.appearsInRecordsArchive == (kind != .healthData), "\(kind.rawValue)")
        }
        #expect(TimelineEntryKind.selfMeasured.appearsInRecordsArchive)
        #expect(TimelineEntryKind.lab.appearsInRecordsArchive)
        #expect(TimelineEntryKind.observation.appearsInRecordsArchive)
    }
}
