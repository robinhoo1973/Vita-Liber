import Foundation
import Testing
@testable import Domain

// binds: SU-M2-HEALTHSYNC
/// FR16.1 首次回填分道（round2 H-N1）与 Apple 健康可见性三态（round2 H1/H3/H-N3/H-N4/H-N5）
/// Domain 纯函数金样：两道谓词以样本 end 在 cutoff 处互补分割；页面状态严格按优先级判定。
@Suite("SU-M2-HEALTHSYNC · 回填分道与可见性三态")
struct HealthFetchScopeTests {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test("H-N1 两道以样本 end 在 cutoff 处互补分割；cutoff = connectedAt − 365 日历日")
    /// 原名：分道互补
    func laneComplementarity() {
        let connected = Date(timeIntervalSince1970: 1_800_000_000)
        let scopes = HealthFetchScope.scopes(connectedAt: connected, calendar: utc)
        #expect(scopes.map(\.lane) == [.recent, .history])
        let cutoff = scopes[0].cutoff
        #expect(scopes[1].cutoff == cutoff)   // 两道边界必须同一时刻，否则出现缝隙或双计
        #expect(utc.dateComponents([.day], from: cutoff, to: connected).day == HealthFetchScope.recentDays)
        #expect(HealthFetchScope.cutoff(connectedAt: connected, calendar: utc) == cutoff)
        // end 恰在 cutoff：HealthKit 默认样本谓词左闭 → recent；history 用 strictEndDate 右开排除
        let straddling = HealthSampleReference(id: UUID(), kind: .steps, sourceID: "s",
                                               start: cutoff.addingTimeInterval(-3600), end: cutoff)
        let older = HealthSampleReference(id: UUID(), kind: .steps, sourceID: "s",
                                          start: cutoff.addingTimeInterval(-7200), end: cutoff.addingTimeInterval(-1))
        let newer = HealthSampleReference(id: UUID(), kind: .steps, sourceID: "s",
                                          start: cutoff, end: cutoff.addingTimeInterval(60))
        #expect(scopes[0].matches(straddling) && !scopes[1].matches(straddling))
        #expect(!scopes[0].matches(older) && scopes[1].matches(older))
        #expect(scopes[0].matches(newer) && !scopes[1].matches(newer))
    }

    @Test("H-N1 分道可编解码（pending 载荷携 lane；旧载荷缺键由存储层作废）")
    /// 原名：分道编解码
    func laneCodable() throws {
        let scope = HealthFetchScope(lane: .history, cutoff: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(scope)
        #expect(try JSONDecoder().decode(HealthFetchScope.self, from: data) == scope)
        #expect(HealthFetchLane.allCases.map(\.rawValue) == ["recent", "history"])
    }

    @Test("H1/H3 可见性三态优先级：关闭 > 不可用 > 缺本人 > 未连接 > 已连接")
    /// 原名：可见性
    func visibility() {
        typealias V = HealthImportVisibility
        #expect(V.state(enabled: false, available: true, ownerPresent: true, connected: true, importedRows: 9) == .disabled)
        #expect(V.state(enabled: false, available: false, ownerPresent: false, connected: false, importedRows: 0) == .disabled)
        #expect(V.state(enabled: true, available: false, ownerPresent: true, connected: false, importedRows: 0) == .unavailable)
        #expect(V.state(enabled: true, available: false, ownerPresent: false, connected: true, importedRows: 3) == .unavailable)
        #expect(V.state(enabled: true, available: true, ownerPresent: false, connected: false, importedRows: 0) == .ownerMissing)
        #expect(V.state(enabled: true, available: true, ownerPresent: true, connected: false, importedRows: 0) == .notConnected)
        #expect(V.state(enabled: true, available: true, ownerPresent: true, connected: false, importedRows: 5) == .notConnected)
        #expect(V.state(enabled: true, available: true, ownerPresent: true, connected: true, importedRows: 0) == .connectedEmpty)
        #expect(V.state(enabled: true, available: true, ownerPresent: true, connected: true, importedRows: 1) == .visible)
    }

    @Test("H1/H2/H-N5 展示区只在开关开 ∧ 已连接时存在；趋势链接需有数据且身份已知")
    /// 原名：展示区与趋势链接门控
    func dashboardAndTrendLinkGating() {
        typealias V = HealthImportVisibility
        #expect(V.showsImportedData(.visible))
        #expect(V.showsImportedData(.connectedEmpty))
        #expect(!V.showsImportedData(.notConnected))
        #expect(!V.showsImportedData(.disabled))
        #expect(!V.showsImportedData(.unavailable))
        #expect(!V.showsImportedData(.ownerMissing))
        let patient = UUID()
        #expect(V.allowsTrendLink(.visible, patientId: patient))
        #expect(!V.allowsTrendLink(.visible, patientId: nil))          // 缺身份不得回落 currentPatientId（BR-001）
        #expect(!V.allowsTrendLink(.connectedEmpty, patientId: patient))
        #expect(!V.allowsTrendLink(.disabled, patientId: patient))
        #expect(!V.allowsTrendLink(.notConnected, patientId: patient))
    }
}
