import XCTest
import Foundation
import GRDB
import Domain
import Infrastructure
import Protocols
@testable import VitaLiber

// binds: SU-M15-TREND — F7 落库半场（三医院同图/排除恢复/迁移加列）
// binds: SU-M15-VOICE — 备份往返与校验拒绝（FR13.11 退出准则的落库半场）
/// TC-M15 的 GRDB 落库级断言（test-plan §4.5）。
///
/// 为什么必须在 iOS 目标：GRDB 只在 iOS/macOS 链接（ERR#8），CoreKit 的 SPM 测试
/// 目标跑在 Linux 容器里，那里 TrendQueryStore / BackupService 被平台守卫整体
/// 编译排除，断言无处落脚。Domain 半场见 CoreKitTests/M15AcceptanceTests.swift。
@MainActor
final class M15AcceptanceTests: XCTestCase {

    private func makeStore() async throws -> (GRDBStore, UUID) {
        let store = try GRDBStore.inMemory()
        let member = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES (?, '趋势测试患者', '本人', 0, 0)
                """, arguments: [member.uuidString])
            // 导出 envelope 的 selfProfile 经 local_owner.self_patient_id JOIN——
            // 无 owner 行的 profile 不进包（M1c 往返测试同款纪律，ERR#35 前置）
            try db.execute(sql: """
                INSERT INTO local_owner (id, display_name, self_patient_id, created_at)
                VALUES (?, '趋势测试患者', ?, 0)
                """, arguments: [UUID().uuidString, member.uuidString])
        }
        return (store, member)
    }

    private func insertMetric(_ store: GRDBStore, member: UUID,
                              value: Double, origin: String, dayOffset: Double,
                              refLow: Double? = nil, refHigh: Double? = nil,
                              refLabel: String? = nil, excluded: Bool = false,
                              sourceRef: String? = nil) async throws -> UUID {
        let id = UUID()
        try await store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO metric_sample
                  (id, patient_id, metric_key, value, unit, origin, self_measured,
                   excluded, source_ref, ref_low, ref_high, ref_source_label,
                   measured_at, created_at)
                VALUES (?, ?, 'glucose', ?, 'mmol/L', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, member.uuidString, value, origin,
                                 origin == "hospital" ? 0 : 1,
                                 excluded ? 1 : 0, sourceRef, refLow, refHigh, refLabel,
                                 1_700_000_000 + dayOffset * 86400, 1_700_000_000])
        }
        return id
    }

    private var wholeRange: DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: 1_600_000_000),
                     end: Date(timeIntervalSince1970: 1_900_000_000))
    }

    // MARK: - F7 一票否决：三医院同图，参考范围各自显示

    func test_三家医院血糖同图且参考范围各自成带() async throws {
        let (store, member) = try await makeStore()
        _ = try await insertMetric(store, member: member, value: 6.1, origin: "hospital",
                                   dayOffset: 0, refLow: 3.9, refHigh: 6.1,
                                   refLabel: "市一医院", sourceRef: "doc-1")
        _ = try await insertMetric(store, member: member, value: 5.8, origin: "hospital",
                                   dayOffset: 1, refLow: 4.1, refHigh: 5.9,
                                   refLabel: "协和医院", sourceRef: "doc-2")
        _ = try await insertMetric(store, member: member, value: 6.4, origin: "hospital",
                                   dayOffset: 2, refLow: 3.6, refHigh: 6.5,
                                   refLabel: "社区卫生中心", sourceRef: "doc-3")
        // 自测点同图并存（空心）
        _ = try await insertMetric(store, member: member, value: 5.5, origin: "manual", dayOffset: 3)

        let series = try await TrendQueryStore(writer: store.writer)
            .series(for: member, metric: .glucose, range: wholeRange)

        XCTAssertEqual(series.points.count, 4, "三家医院 + 自测点必须同图")
        XCTAssertEqual(series.referenceBands.count, 3,
                       "FR7.2 一票否决：三家医院必须是三条独立参考带，合并即红")
        XCTAssertEqual(Set(series.referenceBands.map(\.sourceLabel)),
                       ["市一医院", "协和医院", "社区卫生中心"])
        // 空心/实心一眼可辨
        XCTAssertEqual(series.points.filter(\.isHollow).count, 1)
        XCTAssertEqual(series.points.filter { !$0.isHollow }.count, 3)
        // 点击任一点回原报告：hospital 点必须带 sourceRef
        XCTAssertTrue(series.points.filter { !$0.isHollow }.allSatisfy { $0.sourceRef != nil },
                      "医院点必须携带回原报告的引用")
    }

    /// FR7.4 排除点软删 → 对照集可见 → 恢复往返
    func test_排除点软删与恢复往返() async throws {
        let (store, member) = try await makeStore()
        let keep = try await insertMetric(store, member: member, value: 6.0,
                                          origin: "manual", dayOffset: 0)
        let bad = try await insertMetric(store, member: member, value: 99.9,
                                         origin: "manual", dayOffset: 1)
        let trends = TrendQueryStore(writer: store.writer)

        try await trends.setExcluded(bad, patientId: member, excluded: true)
        var series = try await trends.series(for: member, metric: .glucose, range: wholeRange)
        XCTAssertEqual(series.points.count, 1, "排除后聚合不含该点")
        XCTAssertEqual(series.points[0].id, keep)
        XCTAssertEqual(series.excludedPoints.count, 1, "对照视图必须能看到已排除点")
        XCTAssertEqual(series.excludedPoints[0].value, 99.9, "软删必须保留原值")

        try await trends.setExcluded(bad, patientId: member, excluded: false)
        series = try await trends.series(for: member, metric: .glucose, range: wholeRange)
        XCTAssertEqual(series.points.count, 2, "恢复后重新参与聚合")
        XCTAssertTrue(series.excludedPoints.isEmpty)
    }

    /// BR-001 成员隔离：排除操作不得跨成员生效
    func test_排除操作成员隔离() async throws {
        let (store, member) = try await makeStore()
        let id = try await insertMetric(store, member: member, value: 6.0,
                                        origin: "manual", dayOffset: 0)
        let trends = TrendQueryStore(writer: store.writer)
        try await trends.setExcluded(id, patientId: UUID(), excluded: true)   // 他人 id
        let series = try await trends.series(for: member, metric: .glucose, range: wholeRange)
        XCTAssertEqual(series.points.count, 1, "跨成员排除必须无效（BR-001）")
    }

    // MARK: - 迁移版本序列（滞留 #7）

    /// 全新库直接落到最新版本，且参考范围三列可写
    func test_全新库落最新版本且含参考范围列() async throws {
        let store = try GRDBStore.inMemory()
        let version = try await store.writer.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        XCTAssertEqual(version, SchemaMigrations.latestVersion)
        let cols = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('metric_sample')")
        }
        for c in ["ref_low", "ref_high", "ref_source_label"] {
            XCTAssertTrue(cols.contains(c), "缺列 \(c)，FR7.2 在数据层无处落脚")
        }
    }

    /// **旧库升级路径**：停留在 v1 且缺列的库，必须被迁移补齐——
    /// 旧实现 `version > 0` 是空分支，新列永远到不了已装机的库。
    func test_旧版本库升级补齐新列() async throws {
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        // 手工造一个「v1 但缺列」的库：建表后去掉三列的等价形态
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE patient_profile (
                  id TEXT PRIMARY KEY, display_name TEXT NOT NULL, relation TEXT NOT NULL,
                  gender TEXT, birth_date TEXT, note TEXT,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE TABLE metric_sample (
                  id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patient_profile(id),
                  metric_key TEXT NOT NULL, value REAL NOT NULL, secondary_value REAL,
                  unit TEXT NOT NULL, origin TEXT NOT NULL, self_measured INTEGER NOT NULL,
                  excluded INTEGER NOT NULL DEFAULT 0, source_ref TEXT,
                  measured_at REAL NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE guideline_source (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, org TEXT NOT NULL,
                  year INTEGER NOT NULL, clause_ref TEXT NOT NULL,
                  citation_url TEXT NOT NULL, version TEXT NOT NULL,
                  checked_at REAL NOT NULL, retired_at REAL);
                PRAGMA user_version = 1;
                """)
        }
        let before = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('metric_sample')")
        }
        XCTAssertFalse(before.contains("ref_low"), "前提：升级前确实缺列")

        _ = try GRDBStore(writer: queue)      // 触发迁移

        let after = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('metric_sample')")
        }
        for c in ["ref_low", "ref_high", "ref_source_label"] {
            XCTAssertTrue(after.contains(c), "迁移未补齐 \(c)")
        }
        let version = try await queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        XCTAssertEqual(version, SchemaMigrations.latestVersion)
    }

    /// 幂等：同一 writer 二次装配不得因「表已存在 / 列重复」崩溃
    func test_二次装配幂等() async throws {
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        _ = try GRDBStore(writer: queue)
        XCTAssertNoThrow(try GRDBStore(writer: queue), "持久库二次启动必须不崩（滞留 #7）")
    }

    // MARK: - FR13.11 备份往返与校验（一票否决：损坏包不得部分导入）

    func test_备份往返一致() async throws {
        let (store, _) = try await makeStore()
        let pkg = try await BackupService(writer: store.writer).createBackup()
        XCTAssertFalse(pkg.data.isEmpty)
        XCTAssertEqual(pkg.sha256.count, 64, "sha256 十六进制串应为 64 字符")

        let fresh = try GRDBStore.inMemory()
        try await BackupService(writer: fresh.writer).restore(from: pkg.data)
        let count = try await fresh.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM patient_profile") ?? 0
        }
        XCTAssertGreaterThan(count, 0, "恢复后档案必须存在")
    }

    /// 篡改一个字节 → 校验必须拒绝，且**不得发生任何部分导入**
    func test_损坏备份被校验拒绝且零部分导入() async throws {
        let (store, _) = try await makeStore()
        let pkg = try await BackupService(writer: store.writer).createBackup()

        // 外层信封 = {sha256, payload(编码)}——翻转 payload 的一个字节，
        // 结构依旧合法但 sha256 必然失配
        struct Outer: Codable { var sha256: String; var payload: Data }
        let decoder = JSONDecoder()
        var outer: Outer
        do { outer = try decoder.decode(Outer.self, from: pkg.data) }
        catch { return XCTFail("前提：备份外层信封应可解——\(error)") }
        guard outer.payload.count > 4 else {
            return XCTFail("前提：payload 应有足够字节")
        }
        outer.payload[outer.payload.startIndex] ^= 0xFF
        let tampered = try JSONEncoder().encode(outer)

        let fresh = try GRDBStore.inMemory()
        do {
            try await BackupService(writer: fresh.writer).restore(from: tampered)
            XCTFail("损坏备份必须被拒绝——校验形同虚设即一票否决")
        } catch BackupService.BackupError.checksumMismatch {
            // 期望路径
        }
        let count = try await fresh.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM patient_profile") ?? 0
        }
        XCTAssertEqual(count, 0, "校验失败后不得留下任何部分导入的数据")
    }
}

// binds: SU-M15-L10N — 三文件本地化纪律（zh-Hans / zh-Hant / en 键集一致）
/// dev-pm 横切 NFR：本地化三文件纪律。
///
/// 断言的是**键集一致**而不是「文案好不好」——缺翻译在运行期表现为界面直接显示
/// key 字符串（如 `voice.confirm.title`），是用户可见缺陷，且只有遍历才发现得了。
final class M15LocalizationTests: XCTestCase {

    /// 每个已登记 key 在三个本地化里都必须有真实译文（不等于 key 本身、非空）
    func test_SU_M15_L10N_三文件键集一致且无缺译() throws {
        var missing: [String] = []
        for localization in L10n.supportedLocalizations {
            guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("缺少本地化 \(localization).lproj——三文件纪律不成立")
                continue
            }
            for key in L10n.registeredKeys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                if value == key || value.isEmpty {
                    missing.append("\(localization):\(key)")
                }
            }
        }
        XCTAssertTrue(missing.isEmpty, "缺译 \(missing.count) 处：\(missing.prefix(10))")
    }

    /// 登记表不得为空——空集判过正是 ERR#27 的原始形态
    func test_键登记表非空() {
        XCTAssertFalse(L10n.registeredKeys.isEmpty, "空集不得判过（ERR#27）")
        XCTAssertEqual(Set(L10n.registeredKeys).count, L10n.registeredKeys.count,
                       "登记表存在重复 key")
        XCTAssertEqual(Set(L10n.supportedLocalizations), ["zh-Hans", "zh-Hant", "en"])
    }

    /// 简繁必须真的不同——zh-Hant 直接复制 zh-Hans 是「假装支持繁体」
    func test_简繁译文并非整体复制() throws {
        guard let hansPath = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
              let hans = Bundle(path: hansPath),
              let hantPath = Bundle.main.path(forResource: "zh-Hant", ofType: "lproj"),
              let hant = Bundle(path: hantPath) else {
            return XCTFail("简繁本地化包缺失")
        }
        var differing = 0
        for key in L10n.registeredKeys {
            let a = hans.localizedString(forKey: key, value: nil, table: nil)
            let b = hant.localizedString(forKey: key, value: nil, table: nil)
            if a != b { differing += 1 }
        }
        XCTAssertGreaterThan(differing, L10n.registeredKeys.count / 4,
                             "zh-Hant 与 zh-Hans 差异过少，疑似整体复制未真正转换")
    }
}
