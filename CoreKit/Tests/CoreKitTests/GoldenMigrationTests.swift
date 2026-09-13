import Foundation
import Testing
#if os(iOS) || os(macOS)
import GRDB   // 平台边界（ERR#8）：GRDB 仅 iOS/macOS 链接，Linux 只跑 Domain 门禁
#endif
@testable import Domain
@testable import Infrastructure

// binds: SU-M0-GOLDEN — TC-M0-01~05
@Suite("SU-M0-GOLDEN · M0 迁移金样（Sprint-1）")
struct GoldenMigrationTests {
    @Test func 空数组正常迁移零条() {
        #expect(MigrationEngine.migrate(recordsJSON: Data("[]".utf8)) == .migrated(count: 0))
    }
    @Test func 损坏JSON只读降级不落种子() {
        #expect(MigrationEngine.migrate(recordsJSON: Data("{\"broken".utf8)) == .degraded)
    }
    @Test func 未确认字段不得入时间轴_BR003() {
        var f = FieldConfirmation.ocrUnconfirmed
        #expect(!f.isUsableInTimeline)
        f.confirm()
        #expect(f.isUsableInTimeline && f == .confirmed)
    }
    @Test func DDL外键引用目标已定义() {
        #expect(MigrationEngine.schemaV1.contains("REFERENCES patient_profile(id)"))
    }
}

// binds: SU-M1a-GOLDEN — 阶段金样扩充
@Suite("SU-M1a-GOLDEN · M0 Sprint-3 三类补充")
struct GoldenClassifyTests {
    static let fixtures = Bundle.module.bundlePath + "/Fixtures"
    func load(_ name: String) throws -> [LegacyRecord] {
        try JSONDecoder().decode([LegacyRecord].self, from: Data(contentsOf: URL(fileURLWithPath: Self.fixtures + "/" + name)))
    }
    @Test func 处方类识别与置信度分级() throws {
        let r = try load("prescription_v1.json")[0]
        #expect(GoldenRules.classify(recordType: r.recordType, assets: r.assets) == .prescription)
        #expect(GoldenRules.confidenceTier(0.91) == "high" && GoldenRules.confidenceTier(0.62) == "mid")
    }
    @Test func 化验类识别() throws {
        let r = try load("lab_v1.json")[0]
        #expect(GoldenRules.classify(recordType: r.recordType, assets: r.assets) == .lab)
    }
    @Test func OCR分隔块优先于类型判断() throws {
        let r = try load("ocr_blocks_v1.json")[0]
        #expect(GoldenRules.classify(recordType: r.recordType, assets: r.assets) == .ocrBlock)
        #expect(GoldenRules.confidenceTier(0.85) == "high")
    }
}

@Suite("Golden · M0 Sprint-4 LoadGate/审计")
struct LoadGateAuditTests {
    @Test func LoadGate并发仅加载一次() async {
        let gate = LoadGate()
        actor Counter { var n = 0; func inc() { n += 1 }; var v: Int { n } }
        let c = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<20 { g.addTask { try? await gate.enter { await c.inc() } } }   // try?-ok: inc 无抛错路径；等待者失败传播由 LoadGate 失败用例独立覆盖
        }
        #expect(await c.v == 1)                       // 幂等：20 并发只触发一次加载
        #expect(await gate.currentState == .ready)
    }
    @Test func 审计表外键指向已定义表() {
        #expect(MigrationEngine.schemaV1.contains("audit_event"))
        #expect(MigrationEngine.schemaV1.contains("REFERENCES patient_profile(id)"))
    }

    /// 评审 S1-1 修正用例：load 抛错 → gate 回 .idle（可重试），等待者被唤醒，
    /// 错误只 rethrow 给发起方；重试成功后正常进 .ready。
    @Test func LoadGate失败回idle且可重试() async throws {
        struct Boom: Error {}
        let gate = LoadGate()
        // Swift 6 收敛：enter 闭包为 @Sendable，捕获 var 计数触发「变异捕获
        // 逃逸」警告（LoadGate 在自身执行器上串行执行闭包，与「并发」无关——
        // 原注释表述有误，已纠正）；计数下沉为与同文件兄弟用例一致的
        // actor Counter，@unchecked Sendable 不再必要。
        actor Counter { var n = 0; func inc() { n += 1 }; var v: Int { n } }
        let attempt = Counter()
        var firstErrorReachedCaller = false
        do {
            try await gate.enter {
                await attempt.inc()
                if await attempt.v == 1 { throw Boom() }
            }
        } catch {
            firstErrorReachedCaller = true  // 第一次失败，错误到达发起方
        }
        #expect(firstErrorReachedCaller)
        #expect(await gate.currentState == .idle)          // 失败不得置 ready
        try await gate.enter { await attempt.inc() }       // 重试走 idle 分支
        #expect(await gate.currentState == .ready)
        #expect(await attempt.v == 2)
    }

    /// 第七轮补充锚点：失败时有并发等待者——全部任务（发起方 + 等待者 +
    /// 失败后重试者）都收到错误，不得有任务误以为成功（第六轮「等待者
    /// rethrow」修复此前无并发用例守护；`failure = nil` 与
    /// `waiters.resume` 的次序契约由本用例钉住）
    @Test func LoadGate失败并发等待者全收到错误() async {
        struct Boom: Error {}
        let gate = LoadGate()
        actor Counter { var n = 0; func inc() { n += 1 }; var v: Int { n } }
        let errors = Counter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 {
                g.addTask {
                    do {
                        try await gate.enter {
                            // 留出等待者到达窗口：首个发起方挂起时其余任务进入
                            // .loading 分支成为等待者，失败唤醒后 rethrow 路径
                            // 被真实执行
                            try? await Task.sleep(nanoseconds: 50_000_000)   // try?-ok: 睡眠取消无副作用
                            throw Boom()
                        }
                    } catch {
                        await errors.inc()
                    }
                }
            }
        }
        #expect(await errors.v == 8, "失败不得被任何等待者/重试者吞掉——全部收到错误")
        #expect(await gate.currentState == .idle, "失败后必须回 idle（可重试，不得误置 ready）")
    }

    /// dev-pm §3.1：金样五类样本 + flutter 版真实备份样本一份。
    /// 混型样本覆盖 prescription/lab/medication/other/空资产五种形态——
    /// 断言「迁移条数等于输入条数」且「分类路由与实际类型一致」。
    @Test func flutter真实备份样本无损迁移() throws {
        let fixture = Bundle.module.bundlePath + "/Fixtures/flutter_backup_v1.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
        #expect(MigrationEngine.migrate(recordsJSON: data) == .migrated(count: 6))
        let records = try JSONDecoder().decode([LegacyRecord].self, from: data)
        #expect(GoldenRules.classify(recordType: records[0].recordType, assets: records[0].assets) == .prescription)
        #expect(GoldenRules.classify(recordType: records[1].recordType, assets: records[1].assets) == .lab)
        #expect(GoldenRules.classify(recordType: records[2].recordType, assets: records[2].assets) == .ocrBlock)  // other+OCR块→兜底
        #expect(GoldenRules.classify(recordType: records[3].recordType, assets: records[3].assets) == .generic)
        #expect(GoldenRules.classify(recordType: records[4].recordType, assets: records[4].assets) == .generic)  // 未知类型+无资产
        #expect(GoldenRules.classify(recordType: records[5].recordType, assets: records[5].assets) == .prescription)  // medication→处方
    }

    /// §4.3 自洽性（静态半场的补强，Linux 即可执行）：全量 DDL 里每个 REFERENCES
    /// 目标表都必须有 CREATE TABLE——与 L0 [3/7] 同语义，但直接作用在规范 DDL 上，
    /// 防「表名拼写漂移」类缺陷在 iOS 建库时才爆炸。
    @Test func 全量DDL引用目标自洽() {
        let ddl = MigrationEngine.schemaV1
        let created = Set(ddl
            .replacingOccurrences(of: "IF NOT EXISTS ", with: "")
            .split(separator: ";")
            .compactMap { stmt -> String? in
                let s = String(stmt)
                guard let r = s.range(of: "CREATE TABLE ") else { return nil }
                let rest = String(s[r.upperBound...])
                return rest.prefix(while: { $0 != "(" && $0 != " " }).description.trimmingCharacters(in: .whitespaces)
            })
        let refs = Set(ddl
            .split(separator: ";")
            .compactMap { stmt -> String? in
                let s = String(stmt)
                guard let r = s.range(of: "REFERENCES ") else { return nil }
                let rest = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return rest.prefix(while: { $0 != "(" && $0 != " " && $0 != "\n" }).description
            })
        let missing = refs.subtracting(created)
        #expect(missing.isEmpty, "悬空 REFERENCES 目标: \(missing.sorted())")
    }
}

// 迁移切分器必须支持触发器体（v6 起 CREATE TRIGGER 块内含分号——
// 按 BEGIN/END 配对整块保留，否则 GRDB 执行到残句报 incomplete input，迁移半途而废）
@Suite("M1b · v6 迁移语句切分（Linux 可执行）")
struct MigrationStatementsTests {
    @Test func v6步骤切出完整触发器块() {
        let step6 = SchemaMigrations.steps.first { $0.version == 6 }
        #expect(step6 != nil, "v6 步骤必须存在")
        guard let step6 else { return }
        let stmts = SchemaMigrations.statements(step6.sql)
        #expect(stmts.count == 10, "3 DROP TRIGGER + 4 索引重洗 + 3 CREATE TRIGGER，实得 \(stmts.count)")
        let triggers = stmts.filter { $0.hasPrefix("CREATE TRIGGER") }
        #expect(triggers.count == 3, "三个触发器整块保留")
        for t in triggers {
            #expect(t.hasSuffix("END;"), "触发器必须整条成句：\(t.prefix(60))")
        }
        let drops = stmts.filter { $0.hasPrefix("DROP TRIGGER") }
        #expect(drops.count == 3, "DROP TRIGGER 不得被吞")
    }

    /// v6 的语义次序：先删旧触发器 → 重洗索引 → 再挂新触发器。
    /// 这里断言的是**书写顺序被忠实保留**，而不是「切分器把触发器挪到末尾」——
    /// 后者是隐式副作用，曾让 v6 恰好正确、也让未来错序无人可察。
    @Test func v6语义次序_删除先于重洗先于新建() {
        guard let step6 = SchemaMigrations.steps.first(where: { $0.version == 6 }) else {
            Issue.record("v6 步骤必须存在"); return
        }
        let stmts = SchemaMigrations.statements(step6.sql)
        let lastDrop = stmts.lastIndex { $0.hasPrefix("DROP TRIGGER") }
        let firstRewash = stmts.firstIndex { $0.contains("'delete-all'") }
        let firstCreate = stmts.firstIndex { $0.hasPrefix("CREATE TRIGGER") }
        guard let lastDrop, let firstRewash, let firstCreate else {
            Issue.record("三段必须都在"); return
        }
        #expect(lastDrop < firstRewash, "旧触发器必须先删，重洗期间不得有触发器在挂")
        #expect(firstRewash < firstCreate, "重洗必须早于挂新触发器")
    }

    /// 切分器必须按书写顺序输出——旧实现把所有 CREATE TRIGGER 收集后追加到末尾，
    /// 任何「先建触发器、再灌依赖它的数据」的步骤都会静默错序（SQLite 两种顺序都不报错）
    @Test func 保持书写顺序_触发器不被挪到末尾() {
        let sql = """
        CREATE TRIGGER t1 AFTER INSERT ON a BEGIN
          INSERT INTO b(x) VALUES (new.x);
        END;
        INSERT INTO a(x) VALUES (1);
        """
        let stmts = SchemaMigrations.statements(sql)
        #expect(stmts.count == 2)
        #expect(stmts.first?.hasPrefix("CREATE TRIGGER t1") == true, "触发器书写在前就必须执行在前")
        #expect(stmts.last?.hasPrefix("INSERT INTO a") == true)
    }

    /// 旧实现要求 `END;` 独占一行，否则触发器块被吞掉后续语句
    @Test func END与其他内容同行也能正确闭合() {
        let sql = """
        CREATE TRIGGER t AFTER INSERT ON a BEGIN INSERT INTO b(x) VALUES (new.x); END;
        INSERT INTO c(y) VALUES (2);
        """
        let stmts = SchemaMigrations.statements(sql)
        #expect(stmts.count == 2, "实得 \(stmts.count)：\(stmts)")
        #expect(stmts[0].hasPrefix("CREATE TRIGGER t") && stmts[0].hasSuffix("END;"))
        #expect(stmts[1].hasPrefix("INSERT INTO c"))
    }

    /// 触发器体内的 CASE … END 不得被当成体结束标记（v6 的守卫正是 CASE 形态）
    @Test func 触发器体内CASE_END不提前闭合() {
        let sql = """
        CREATE TRIGGER t AFTER INSERT ON a BEGIN
          INSERT INTO b(x) VALUES (CASE WHEN new.s = 0 THEN new.x END);
          INSERT INTO d(z) VALUES (CASE WHEN new.s = 1 THEN new.z END);
        END;
        INSERT INTO c(y) VALUES (3);
        """
        let stmts = SchemaMigrations.statements(sql)
        #expect(stmts.count == 2, "CASE 的 END 被误当体结束会切出多余语句：\(stmts.count)")
        #expect(stmts[0].contains("INSERT INTO d"), "体内第二条语句不得被切走")
        #expect(stmts[1].hasPrefix("INSERT INTO c"))
    }

    /// 字符串字面量与注释里的分号不是语句边界
    @Test func 字面量与注释中的分号不切分() {
        let sql = """
        INSERT INTO a(x) VALUES ('semi; colon');
        -- 这行注释里有分号; 不得切
        INSERT INTO a(x) VALUES ('it''s; ok');
        /* 块注释; 同样不切 */
        INSERT INTO a(x) VALUES (1);
        """
        let stmts = SchemaMigrations.statements(sql)
        #expect(stmts.count == 3, "实得 \(stmts.count)：\(stmts)")
        #expect(stmts[0].contains("'semi; colon'"))
        #expect(stmts[1].contains("'it''s; ok'"))
    }

    /// ADD COLUMN 幂等解析在带尾分号的语句上依然成立（切分器保留分号）
    @Test func ADD_COLUMN解析兼容尾分号() {
        let stmts = SchemaMigrations.statements("ALTER TABLE metric_sample ADD COLUMN ref_low REAL;")
        #expect(stmts.count == 1)
        let parts = SchemaMigrations.addColumnParts(stmts[0])
        #expect(parts?.table == "metric_sample")
        #expect(parts?.column == "ref_low")
    }

    /// **全新库与升级库必须装到同一套 FTS 触发器**。
    ///
    /// 触发器 DDL 有意在两处各存一份：`SchemaV2.ddl`（全新库 baseline）与
    /// v6 迁移步骤（老库升级）。不抽公共常量是迁移纪律——已发布的迁移步骤是
    /// **历史记录**，若它插值一个可变常量，后续为 v7 改动该常量会让「从 v3 升上来的设备
    /// 在第 6 步执行未来的 DDL」，历史语义被静默改写。
    ///
    /// 代价是两份副本可能漂移，而漂移后果正是 BR-007/008 的失效形态：
    /// 全新安装不索引敏感正文、升级设备继续索引（或反之），搜索行为按安装历史而异。
    /// 因此用本断言替代抽取：只加固 baseline 而不追加迁移步骤，立刻转红。
    @Test func baseline与v6装的FTS触发器一致() {
        func triggers(in sql: String) -> [String: String] {
            var out: [String: String] = [:]
            for stmt in SchemaMigrations.statements(sql) where stmt.hasPrefix("CREATE TRIGGER") {
                let normalized = stmt.split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                guard let name = normalized.split(separator: " ").dropFirst(2).first else { continue }
                out[String(name)] = normalized
            }
            return out
        }
        let baseline = triggers(in: SchemaV2.ddl)
            .filter { $0.key.hasPrefix("document_file_fts_") }
        guard let step6 = SchemaMigrations.steps.first(where: { $0.version == 6 }) else {
            Issue.record("v6 步骤必须存在"); return
        }
        let migrated = triggers(in: step6.sql)
            .filter { $0.key.hasPrefix("document_file_fts_") }

        #expect(baseline.count == 3, "baseline 应有 3 个 FTS 同步触发器，实得 \(baseline.count)")
        #expect(Set(baseline.keys) == Set(migrated.keys),
                "触发器集合不一致 baseline=\(baseline.keys.sorted()) v6=\(migrated.keys.sorted())")
        for (name, sql) in baseline {
            #expect(migrated[name] == sql,
                    "触发器 \(name) 在 baseline 与 v6 之间漂移——加固 baseline 必须同时追加迁移步骤")
        }
    }
}

@Suite("M0 · MockFactory 三实体（Preview 出口准则）")
struct MockFactoryTests {
    @Test func 三类工厂产出合法关联实体() {
        let p = MockFactory.patient()
        let d = MockFactory.document(for: p)
        let m = MockFactory.plan(for: p)
        #expect(d.patientId == p.id && m.patientId == p.id)
        #expect(m.status == .active && !p.displayName.isEmpty)
    }
}

// binds: SU-M1b-GOLDEN 扩充 —— v6 迁移必须让老库获得与全新库同等的 FTS 敏感加固
// GRDB 平台边界：本套件仅 iOS/macOS（L1）执行；SQL 正确性在 Linux 由
// l0-static-gate 的 DDL 断言 + macOS 侧本套件双重把关。
#if os(iOS) || os(macOS)
@Suite("M1b · v6 FTS 敏感加固迁移（BR-007/008 老库触发器重建 + 索引重洗）")
struct FtsSensitiveMigrationTests {
    /// 模拟 v1–v5 老库：baseline DDL 建库后把触发器替换回「无条件索引」旧形态，
    /// 插入敏感文档 → 迁移前敏感笔记可被搜中 → 应用 v6 → 笔记词条被清、标题词条保留。
    @Test func 老库敏感笔记迁移后不再可检索() throws {
        let dbQueue = try DatabaseQueue(configuration: GRDBStore.configuration())
        try dbQueue.write { db in
            try db.execute(sql: MigrationEngine.schemaV1)
            for t in ["document_file_fts_ai", "document_file_fts_au", "document_file_fts_ad"] {
                try db.execute(sql: "DROP TRIGGER \(t)")
            }
            // 旧触发器：notes/ocr_text 无条件入索引（敏感正文泄漏进 FTS 的根因）
            try db.execute(sql: """
                CREATE TRIGGER document_file_fts_ai AFTER INSERT ON document_file BEGIN
                  INSERT INTO document_fts(rowid, title, ocr_text, notes)
                    VALUES (new.rowid, new.title, new.ocr_text, new.notes);
                  INSERT INTO document_fts_2gram(rowid, title_2gram, ocr_2gram, note_2gram)
                    VALUES (new.rowid, bigrams(new.title), bigrams(new.ocr_text), bigrams(new.notes));
                END;
                """)
            try db.execute(sql: """
                INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at)
                VALUES ('p1', '测试', '本人', 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, status, sha256, mime_type,
                                           is_sensitive, origin, title, ocr_text, notes,
                                           created_at, updated_at)
                VALUES ('d1', 'p1', 'report', 'active', 'h1', 'text/plain',
                        1, 'import', '年度体检报告', '敏感正文内容', '敏感笔记内容', 0, 0)
                """)
        }
        var noteHitsBefore = 0
        var titleHitsBefore = 0
        try dbQueue.read { db in
            noteHitsBefore = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM document_fts WHERE document_fts MATCH ?
                """, arguments: ["敏感笔记"]) ?? 0
            titleHitsBefore = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM document_fts WHERE document_fts MATCH ?
                """, arguments: ["体检报告"]) ?? 0
        }
        #expect(noteHitsBefore > 0, "旧触发器下敏感笔记应已入索引（测试前提）")
        #expect(titleHitsBefore > 0, "标题词条应已入索引（测试前提）")

        // 只应用 v6：本套件验证 FTS 加固本身。步骤 7–15 为 ALTER ADD COLUMN，
        // 生产路径经 GRDBStore 幂等包装（列存在即跳过），本测试以 raw db.execute
        // 直连重放时 v8 会在「baseline 已含 hospital 等列」的全量库上撞
        // duplicate column（CI 34018919463 实证）——步骤 7–15 与本测试前提无关。
        let v6 = SchemaMigrations.pending(from: 5).first { $0.version == 6 }
        #expect(v6 != nil, "v6 步骤必须存在于迁移序列")
        try dbQueue.write { db in
            if let v6 {
                for statement in SchemaMigrations.statements(v6.sql) {
                    try db.execute(sql: statement)
                }
            }
        }

        var noteHitsAfter = 0
        var titleHitsAfter = 0
        try dbQueue.read { db in
            noteHitsAfter = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM document_fts WHERE document_fts MATCH ?
                """, arguments: ["敏感笔记"]) ?? 0
            titleHitsAfter = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM document_fts WHERE document_fts MATCH ?
                """, arguments: ["体检报告"]) ?? 0
        }
        #expect(noteHitsAfter == 0, "BR-007/008：敏感笔记词条必须被重洗清除")
        #expect(titleHitsAfter > 0, "敏感文档仍按元数据（标题）可检索")

        // 幂等重放：v6 再跑一遍不炸、结果不变
        try dbQueue.write { db in
            if let v6 {
                for statement in SchemaMigrations.statements(v6.sql) {
                    try db.execute(sql: statement)
                }
            }
        }
        try dbQueue.read { db in
            let again = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM document_fts WHERE document_fts MATCH ?
                """, arguments: ["敏感笔记"]) ?? 0
            #expect(again == 0, "v6 重放必须幂等")
        }
    }
}

// binds: SU-M0-GOLDEN — 子项目 D · D1-1：v24→v25 `recognition-fact-lines` 老库逐步升级金样
// （discussions/2026-09-13-hospital-card-schema-round1 §D.0/§D.4）。
// GRDB 平台边界：仅 iOS/macOS（CI `cd CoreKit && swift test`）执行；Linux 侧由
// .github/workflows/test-schema-integrity.py 以 sqlite3 复核同一 v25 SQL 步。
// 夹具 schema_v24_baseline.sql = 改基线**之前**从 HEAD 冻结的 SchemaV2.ddl 全文。
@Suite("SU-M0-GOLDEN · v24→v25 老库逐步升级 = 全新库基线 / 回填幂等")
struct SchemaV25GoldenTests {
    static let fixture = Bundle.module.bundlePath + "/Fixtures/schema_v24_baseline.sql"
    /// v24 老库经 GRDBStore 走完整链（v25 → v26 …），故列集比对也覆盖 v26 五表与 metric_sample 增列
    /// （D2-1：v24→v25→v26 逐步升级 = 全新库基线，§D.4 验证合同）。
    static let tables = ["encounter", "prescription", "prescription_line", "claim_item", "claim_line",
                         "document_file", "stock_lot", "ocr_card_commit",
                         "hospitalization", "diagnosis", "exam_report", "lab_report", "lab_result", "metric_sample"]

    struct Legacy {
        let queue: DatabaseQueue
        let patient: UUID
        let document: UUID
    }

    /// v24 老库：冻结基线 + `PRAGMA user_version = 24` + 一位成员 / 一份文档 / 第 0 页。
    /// 必须用 GRDBStore.configuration()：基线触发器调用 bigrams()，且外键开启才与生产库同形。
    static func legacyDatabase() throws -> Legacy {
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        let patient = UUID(), document = UUID()
        let ddl = String(decoding: try Data(contentsOf: URL(fileURLWithPath: Self.fixture)), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: ddl)
            try db.execute(sql: "PRAGMA user_version = 24")
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'A', 'self', 0, 0)",
                           arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, sha256, mime_type, origin, created_at, updated_at)
                VALUES (?, ?, '处方单', 'h', 'image/png', 'import', 0, 0)
                """, arguments: [document.uuidString, patient.uuidString])
            try db.execute(sql: "INSERT INTO document_page (id, document_file_id, page_index, created_at) VALUES (?, ?, 0, 0)",
                           arguments: [UUID().uuidString, document.uuidString])
        }
        return Legacy(queue: queue, patient: patient, document: document)
    }

    /// v24 形态回执（无 entity_table 列）+ ocr-card-v22 审计 JSON（ocr_result 只增不改）。
    static func insertLegacyReceipt(_ db: Database, _ audit: OCRCardStore.AuditRecord) throws {
        try db.execute(sql: """
            INSERT INTO ocr_card_commit (card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [audit.cardId.uuidString, audit.rowId.uuidString, audit.patientId.uuidString, audit.documentId.uuidString,
                             audit.pageIndex, audit.cardKind, audit.entityId.uuidString, audit.recordedAt.timeIntervalSince1970])
        try db.execute(sql: """
            INSERT INTO ocr_result (id, document_file_id, page_index, raw_blocks, engine_version, created_at)
            VALUES (?, ?, ?, ?, 'ocr-card-v22', ?)
            """, arguments: [UUID().uuidString, audit.documentId.uuidString, audit.pageIndex,
                             String(decoding: try JSONEncoder().encode(audit), as: UTF8.self), audit.recordedAt.timeIntervalSince1970])
    }

    /// pragma_table_info 逐列签名（名/类型/notnull/默认/pk），按列名排序——基线表尾追加与迁移 ADD COLUMN 顺序无关。
    static func columns(_ db: Database, _ table: String) throws -> [String] {
        try Row.fetchAll(db, sql: "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?)", arguments: [table]).map { row in
            "\(row["name"] as String)|\(row["type"] as String)|\(row["notnull"] as Int)|\((row["dflt_value"] as String?) ?? "NULL")|\(row["pk"] as Int)"
        }.sorted()
    }

    @Test func 逐表列集一致且回填幂等() throws {
        let legacy = try Self.legacyDatabase()
        let card = UUID(), header = UUID()
        try legacy.queue.write { db in
            try db.execute(sql: """
                INSERT INTO prescription (id, patient_id, document_file_id, source, prescribed_at, advice_text, confirmed, created_at, updated_at)
                VALUES (?, ?, ?, 'ocr', 0, 'Drug A 0.5g\nDrug B', 1, 0, 0)
                """, arguments: [header.uuidString, legacy.patient.uuidString, legacy.document.uuidString])
            for (index, name) in ["Drug A", "Drug B"].enumerated() {
                let audit = OCRCardStore.AuditRecord(
                    cardId: card, rowId: UUID(), patientId: legacy.patient, documentId: legacy.document, pageIndex: 0,
                    cardKind: "prescription", entityId: header,
                    shared: [.init(key: "prescribed_at", value: "2020-01-02", grade: .userConfirmed)],
                    fields: [.init(key: "drug_name", value: name, rawText: "\(name) 0.5g", grade: .userConfirmed),
                             .init(key: "dosage", value: "0.5", unit: "g", grade: .userConfirmed)],
                    recordedAt: Date(timeIntervalSince1970: Double(1 + index)))
                try Self.insertLegacyReceipt(db, audit)
            }
        }
        _ = try GRDBStore(writer: legacy.queue)          // 老库 v24 → v25
        let fresh = try GRDBStore.inMemory()             // 全新库直达基线
        for table in Self.tables {
            let upgraded = try legacy.queue.read { try Self.columns($0, table) }
            let baseline = try fresh.writer.read { try Self.columns($0, table) }
            #expect(upgraded == baseline, "\(table) 列集：老库逐步升级 ≠ 全新库基线")
        }
        try legacy.queue.read { db in
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SchemaMigrations.latestVersion)
            #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1, "迁移后外键必须复位开启")
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check(ocr_card_commit)").isEmpty)
            #expect(try String.fetchAll(db, sql: "SELECT DISTINCT entity_table FROM ocr_card_commit") == ["prescription"],
                    "历史回执搬运 entity_table = card_kind")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_card_commit") == 2, "重建不得丢行")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prescription_line WHERE prescription_id = ? AND patient_id = ? AND confirmed = 1",
                                     arguments: [header.uuidString, legacy.patient.uuidString]) == 2)
            #expect(try String.fetchAll(db, sql: "SELECT printed_name FROM prescription_line ORDER BY ordinal") == ["Drug A", "Drug B"],
                    "ordinal 按回执 created_at 次序")
            #expect(try String.fetchOne(db, sql: "SELECT dose_text || '/' || dose_unit FROM prescription_line WHERE ordinal = 0") == "0.5/g",
                    "剂量只存原文 + 单位，不解析（BR-006/007）")
            #expect(try String.fetchOne(db, sql: "SELECT raw_text FROM prescription_line WHERE ordinal = 0") == "Drug A 0.5g")
            #expect(try String.fetchOne(db, sql: "SELECT id FROM prescription_line WHERE ordinal = 0")
                    == (try String.fetchOne(db, sql: "SELECT source_row_id FROM prescription_line WHERE ordinal = 0")),
                    "行 id = 回执 row_id（确定性，两台设备回填同 id）")
            #expect(try String.fetchOne(db, sql: "SELECT advice_text FROM prescription WHERE id = ?", arguments: [header.uuidString])
                    == "Drug A 0.5g\nDrug B", "advice_text 原样保留，绝不从自由文本猜回")
        }
        try legacy.queue.write { try GRDBStore.backfillRecognitionFactLines($0) }   // 重跑
        #expect(try legacy.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM prescription_line") } == 2, "回填重跑不重复")
    }

    @Test func 就诊叙事与报销列只补空且重跑不覆盖() throws {
        let legacy = try Self.legacyDatabase()
        let encounter = UUID(), claim = UUID()
        try legacy.queue.write { db in
            try db.execute(sql: "INSERT INTO encounter (id, patient_id, date, kind, created_at, updated_at) VALUES (?, ?, 0, 'outpatient', 0, 0)",
                           arguments: [encounter.uuidString, legacy.patient.uuidString])
            try Self.insertLegacyReceipt(db, OCRCardStore.AuditRecord(
                cardId: UUID(), rowId: UUID(), patientId: legacy.patient, documentId: legacy.document, pageIndex: 0,
                cardKind: "encounter", entityId: encounter,
                shared: [.init(key: "date", value: "2020-01-02", grade: .userConfirmed), .init(key: "kind", value: "outpatient", grade: .userConfirmed),
                         .init(key: "present_illness", value: "回执现病史", grade: .userConfirmed),
                         .init(key: "visit_summary", value: "回执小结", grade: .userConfirmed)],
                fields: [], recordedAt: Date(timeIntervalSince1970: 1)))
            try db.execute(sql: """
                INSERT INTO claim_item (id, patient_id, document_file_id, item_type, amount, currency, date, confirmed, created_at, updated_at)
                VALUES (?, ?, ?, 'invoice', 128.5, 'CNY', 0, 1, 0, 0)
                """, arguments: [claim.uuidString, legacy.patient.uuidString, legacy.document.uuidString])
            try Self.insertLegacyReceipt(db, OCRCardStore.AuditRecord(
                cardId: UUID(), rowId: UUID(), patientId: legacy.patient, documentId: legacy.document, pageIndex: 0,
                cardKind: "claim_item", entityId: claim,
                shared: [.init(key: "amount", value: "128.5", grade: .userConfirmed), .init(key: "reimbursed_amount", value: "100", grade: .userConfirmed),
                         .init(key: "out_of_pocket", value: "不是数字", grade: .userConfirmed)],
                fields: [], recordedAt: Date(timeIntervalSince1970: 1)))
        }
        _ = try GRDBStore(writer: legacy.queue)
        try legacy.queue.read { db in
            #expect(try String.fetchOne(db, sql: "SELECT present_illness FROM encounter WHERE id = ?", arguments: [encounter.uuidString]) == "回执现病史")
            #expect(try String.fetchOne(db, sql: "SELECT visit_summary FROM encounter WHERE id = ?", arguments: [encounter.uuidString]) == "回执小结")
            #expect(try Double.fetchOne(db, sql: "SELECT reimbursed_amount FROM claim_item WHERE id = ?", arguments: [claim.uuidString]) == 100)
            #expect(try Double.fetchOne(db, sql: "SELECT out_of_pocket FROM claim_item WHERE id = ?", arguments: [claim.uuidString]) == nil,
                    "不可解析的金额保持 NULL，不猜")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prescription_line") == 0)
            #expect(try Set(String.fetchAll(db, sql: "SELECT DISTINCT entity_table FROM ocr_card_commit")) == ["encounter", "claim_item"])
        }
        // 用户事后改写叙事 → 回填重跑（COALESCE 只补空）不得覆盖
        try legacy.queue.write { db in
            try db.execute(sql: "UPDATE encounter SET present_illness = '用户改写' WHERE id = ?", arguments: [encounter.uuidString])
            try GRDBStore.backfillRecognitionFactLines(db)
        }
        #expect(try legacy.queue.read { try String.fetchOne($0, sql: "SELECT present_illness FROM encounter WHERE id = ?", arguments: [encounter.uuidString]) }
                == "用户改写", "回填只补空——既有叙事不被回执覆盖")
    }

    @Test func 损坏回执跳过不中止迁移() throws {
        let legacy = try Self.legacyDatabase()
        let header = UUID()
        try legacy.queue.write { db in
            try db.execute(sql: """
                INSERT INTO prescription (id, patient_id, document_file_id, source, prescribed_at, confirmed, created_at, updated_at)
                VALUES (?, ?, ?, 'ocr', 0, 1, 0, 0)
                """, arguments: [header.uuidString, legacy.patient.uuidString, legacy.document.uuidString])
            // 回执行在、审计 JSON 损坏（非 AuditRecord 形态）
            try db.execute(sql: """
                INSERT INTO ocr_card_commit (card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_id, created_at)
                VALUES (?, ?, ?, ?, 0, 'prescription', ?, 1)
                """, arguments: [UUID().uuidString, UUID().uuidString, legacy.patient.uuidString, legacy.document.uuidString, header.uuidString])
            try db.execute(sql: """
                INSERT INTO ocr_result (id, document_file_id, page_index, raw_blocks, engine_version, created_at)
                VALUES (?, ?, 0, '{"broken', 'ocr-card-v22', 1)
                """, arguments: [UUID().uuidString, legacy.document.uuidString])
        }
        _ = try GRDBStore(writer: legacy.queue)          // 不抛：坏回执跳过、版本仍推进
        try legacy.queue.read { db in
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SchemaMigrations.latestVersion)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prescription_line") == 0, "无可解回执 → 不生成行")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_card_commit WHERE entity_table = 'prescription'") == 1)
        }
    }
}

// binds: SU-M0-GOLDEN — 子项目 D · D2-1：v25→v26 `clinical-episodes` 老库逐步升级金样
// （discussions/2026-09-13-hospital-card-schema-round1 §C.2–C.5 / §D.2 / §D.4）。
// GRDB 平台边界：仅 iOS/macOS 执行；Linux 侧由 .github/workflows/test-schema-integrity.py
// 以 sqlite3 复核同一 v26 SQL 步（含回填与红线 DDL 断言）。
// 夹具 schema_v25_baseline.sql = 改基线**之前**从 HEAD（v25）冻结的 SchemaV2.ddl 全文。
// v26 为纯 SQL 步（无表重建、无代码回填）：runner default 路径 executeIdempotent 逐语句 + 版本推进。
@Suite("SU-M0-GOLDEN · v25→v26 老库逐步升级 = 全新库基线 / lab_report 回填幂等 / 红线 DDL")
struct SchemaV26GoldenTests {
    static let fixture = Bundle.module.bundlePath + "/Fixtures/schema_v25_baseline.sql"
    static let tables = ["hospitalization", "diagnosis", "exam_report", "lab_report", "lab_result", "metric_sample", "ocr_card_commit"]

    struct Legacy {
        let queue: DatabaseQueue
        let patient: UUID
        let document: UUID
    }

    /// v25 老库：冻结基线 + `PRAGMA user_version = 25` + 一位成员 / 一份检验报告文档 / 第 0、1 页。
    static func legacyDatabase() throws -> Legacy {
        let queue = try DatabaseQueue(configuration: GRDBStore.configuration())
        let patient = UUID(), document = UUID()
        let ddl = String(decoding: try Data(contentsOf: URL(fileURLWithPath: Self.fixture)), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: ddl)
            try db.execute(sql: "PRAGMA user_version = 25")
            try db.execute(sql: "INSERT INTO patient_profile (id, display_name, relation, created_at, updated_at) VALUES (?, 'A', 'self', 0, 0)",
                           arguments: [patient.uuidString])
            try db.execute(sql: """
                INSERT INTO document_file (id, patient_id, doc_type, sha256, mime_type, origin, created_at, updated_at)
                VALUES (?, ?, '检验报告', 'h', 'image/png', 'import', 0, 0)
                """, arguments: [document.uuidString, patient.uuidString])
            for page in 0...1 {
                try db.execute(sql: "INSERT INTO document_page (id, document_file_id, page_index, created_at) VALUES (?, ?, ?, 0)",
                               arguments: [UUID().uuidString, document.uuidString, page])
            }
        }
        return Legacy(queue: queue, patient: patient, document: document)
    }

    /// 历史检验卡的一行：medical hospital 行（origin='hospital'，医院名塞 ref_source_label）+ v25 形态回执
    /// （entity_table = card_kind = 'metric_sample'）。v26 回填只读回执与旧行，不读 ocr_result JSON。
    static func insertLabRow(_ db: Database, legacy: Legacy, id: UUID, card: UUID, page: Int, metric: String, value: Double, unit: String,
                             hospital: String, measuredAt: Double, receiptAt: Double) throws {
        try db.execute(sql: """
            INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, excluded, source_ref,
                                       ref_source_label, raw_label, measured_at, created_at)
            VALUES (?, ?, ?, ?, ?, 'hospital', 0, 0, ?, ?, ?, ?, ?)
            """, arguments: [id.uuidString, legacy.patient.uuidString, metric, value, unit,
                             HospitalSample.sourceRef(documentId: legacy.document, pageIndex: page), hospital, metric, measuredAt, receiptAt])
        try db.execute(sql: """
            INSERT INTO ocr_card_commit (card_id, row_id, patient_id, document_file_id, page_index, card_kind, entity_table, entity_id, created_at)
            VALUES (?, ?, ?, ?, ?, 'metric_sample', 'metric_sample', ?, ?)
            """, arguments: [card.uuidString, UUID().uuidString, legacy.patient.uuidString, legacy.document.uuidString, page, id.uuidString, receiptAt])
    }

    /// 镜像 GRDBStore.executeIdempotent（private）：重放 v26 SQL，ADD COLUMN 已存在则跳过。
    static func replayV26(_ db: Database) throws {
        guard let step = SchemaMigrations.steps.first(where: { $0.version == 26 }) else {
            Issue.record("v26 步骤必须存在"); return
        }
        for statement in SchemaMigrations.statements(step.sql) {
            if let parts = SchemaMigrations.addColumnParts(statement),
               (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?",
                                 arguments: [parts.table, parts.column]) ?? 0) > 0 { continue }
            try db.execute(sql: statement)
        }
    }

    @Test func 逐表列集一致且检验表头回填幂等() throws {
        let legacy = try Self.legacyDatabase()
        let card = UUID(), card2 = UUID()
        let glucose = UUID(), hemoglobin = UUID(), second = UUID(), manual = UUID()
        try legacy.queue.write { db in
            try Self.insertLabRow(db, legacy: legacy, id: glucose, card: card, page: 0, metric: "glucose", value: 5.6, unit: "mmol/L",
                                  hospital: "仁济医院", measuredAt: 1_700_000_000, receiptAt: 10)
            try Self.insertLabRow(db, legacy: legacy, id: hemoglobin, card: card, page: 0, metric: "hemoglobin", value: 135, unit: "g/L",
                                  hospital: "仁济医院", measuredAt: 1_700_000_000, receiptAt: 11)
            try Self.insertLabRow(db, legacy: legacy, id: second, card: card2, page: 1, metric: "glucose", value: 5.1, unit: "mmol/L",
                                  hospital: "仁济医院", measuredAt: 1_700_086_400, receiptAt: 13)
            // 手输行：无回执，不得挂表头
            try db.execute(sql: """
                INSERT INTO metric_sample (id, patient_id, metric_key, value, unit, origin, self_measured, measured_at, created_at)
                VALUES (?, ?, 'glucose', 6.0, 'mmol/L', 'manual', 1, 1700000100, 12)
                """, arguments: [manual.uuidString, legacy.patient.uuidString])
        }
        _ = try GRDBStore(writer: legacy.queue)          // 老库 v25 → v26
        let fresh = try GRDBStore.inMemory()             // 全新库直达基线
        for table in Self.tables {
            let upgraded = try legacy.queue.read { try SchemaV25GoldenTests.columns($0, table) }
            let baseline = try fresh.writer.read { try SchemaV25GoldenTests.columns($0, table) }
            #expect(upgraded == baseline, "\(table) 列集：老库逐步升级 ≠ 全新库基线")
        }
        try legacy.queue.read { db in
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SchemaMigrations.latestVersion)
            #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1, "迁移后外键必须复位开启")
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty, "回填后 lab_report_id 不得悬空")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_report") == 2, "每张历史检验卡一条表头（card_id 同页同卡类唯一）")
            let header = try #require(try Row.fetchOne(db, sql: "SELECT * FROM lab_report WHERE source_card_id = ?", arguments: [card.uuidString]))
            #expect(header["id"] as String == card.uuidString, "表头 id = card_id（确定性、UUID 同型，两台设备回填同 id）")
            #expect(header["patient_id"] as String == legacy.patient.uuidString)
            #expect(header["document_file_id"] as String? == legacy.document.uuidString)
            #expect(header["hospital"] as String? == "仁济医院", "hospital 取旧行 ref_source_label")
            #expect(header["reported_at"] as Double? == 1_700_000_000, "reported_at = 卡内 measured_at")
            #expect(header["source"] as String == "ocr")
            #expect(header["confirmed"] as Int == 1, "只从已确认回执生成（BR-003）")
            #expect(header["created_at"] as Double == 10, "created_at = 回执 MIN(created_at)")
            #expect(header["encounter_id"] as String? == nil, "无信号不猜归属")
            for id in [glucose, hemoglobin] {
                #expect(try String.fetchOne(db, sql: "SELECT lab_report_id FROM metric_sample WHERE id = ?", arguments: [id.uuidString]) == card.uuidString)
            }
            #expect(try String.fetchOne(db, sql: "SELECT lab_report_id FROM metric_sample WHERE id = ?", arguments: [second.uuidString]) == card2.uuidString)
            #expect(try String.fetchOne(db, sql: "SELECT lab_report_id FROM metric_sample WHERE id = ?", arguments: [manual.uuidString]) == nil,
                    "手输行无回执，不挂表头（fetchOne 对 NULL 值返回 nil）")
            #expect(try Double.fetchOne(db, sql: "SELECT measured_at FROM metric_sample WHERE id = ?", arguments: [glucose.uuidString]) == 1_700_000_000,
                    "旧行 measured_at 不改（§C.5）")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metric_sample WHERE abnormal_flag IS NOT NULL") == 0, "回填不臆造异常标志")
        }
        // 幂等：用户事后改写表头 → 重放 v26 不增行、不覆盖
        try legacy.queue.write { db in
            try db.execute(sql: "UPDATE lab_report SET hospital = '用户改写' WHERE id = ?", arguments: [card.uuidString])
            try Self.replayV26(db)
        }
        try legacy.queue.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_report") == 2, "回填重跑不重复")
            #expect(try String.fetchOne(db, sql: "SELECT hospital FROM lab_report WHERE id = ?", arguments: [card.uuidString]) == "用户改写")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metric_sample WHERE lab_report_id IS NOT NULL") == 3)
        }
    }

    @Test func 无历史检验卡零回填且新表约束生效() throws {
        let legacy = try Self.legacyDatabase()
        _ = try GRDBStore(writer: legacy.queue)
        let encounter = UUID()
        try legacy.queue.write { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_report") == 0, "诊断/检查/住院/检验此前无卡 → 零回填")
            try db.execute(sql: "INSERT INTO encounter (id, patient_id, date, kind, created_at, updated_at) VALUES (?, ?, 0, 'inpatient', 0, 0)",
                           arguments: [encounter.uuidString, legacy.patient.uuidString])
            // 成员隔离：每张新表 patient_id 悬空被拒
            let ghosts = [
                "INSERT INTO hospitalization (id, patient_id, encounter_id, source, created_at, updated_at) VALUES ('h9', 'ghost', ?, 'ocr', 0, 0)",
                "INSERT INTO diagnosis (id, patient_id, encounter_id, name, created_at, updated_at) VALUES ('dx9', 'ghost', ?, 'X', 0, 0)",
                "INSERT INTO exam_report (id, patient_id, encounter_id, report_type, source, created_at, updated_at) VALUES ('x9', 'ghost', ?, 'ct', 'ocr', 0, 0)",
                "INSERT INTO lab_report (id, patient_id, encounter_id, source, created_at, updated_at) VALUES ('lr9', 'ghost', ?, 'manual', 0, 0)",
            ]
            for sql in ghosts {
                #expect(throws: DatabaseError.self, "\(sql)") { try db.execute(sql: sql, arguments: [encounter.uuidString]) }
            }
            // CHECK 枚举 canonical raw（展示经 fieldValueDisplay 单出口）
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO exam_report (id, patient_id, report_type, source, created_at, updated_at) VALUES ('x1', ?, 'bogus', 'ocr', 0, 0)",
                               arguments: [legacy.patient.uuidString])
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO diagnosis (id, patient_id, diagnosis_type, name, created_at, updated_at) VALUES ('dx1', ?, 'bogus', 'X', 0, 0)",
                               arguments: [legacy.patient.uuidString])
            }
            // hospitalization 1:0..1 encounter（UNIQUE encounter_id）
            try db.execute(sql: "INSERT INTO hospitalization (id, patient_id, encounter_id, source, confirmed, created_at, updated_at) VALUES ('h1', ?, ?, 'ocr', 1, 0, 0)",
                           arguments: [legacy.patient.uuidString, encounter.uuidString])
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO hospitalization (id, patient_id, encounter_id, source, created_at, updated_at) VALUES ('h2', ?, ?, 'manual', 0, 0)",
                               arguments: [legacy.patient.uuidString, encounter.uuidString])
            }
            // lab_result：定性原文行挂表头，UNIQUE(lab_report_id, ordinal)
            try db.execute(sql: "INSERT INTO lab_report (id, patient_id, source, confirmed, created_at, updated_at) VALUES ('lr1', ?, 'manual', 1, 0, 0)",
                           arguments: [legacy.patient.uuidString])
            try db.execute(sql: "INSERT INTO lab_result (id, patient_id, lab_report_id, ordinal, item_name, result_text, created_at) VALUES ('r1', ?, 'lr1', 0, 'HBsAg', '阴性', 0)",
                           arguments: [legacy.patient.uuidString])
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO lab_result (id, patient_id, lab_report_id, ordinal, item_name, result_text, created_at) VALUES ('r2', ?, 'lr1', 0, 'HBeAg', '阴性', 0)",
                               arguments: [legacy.patient.uuidString])
            }
            // 红线：检查报告无危急值/分级列（BR-004/012）；诊断编码只存打印文本、不 FK 码表（BR-003）
            let examColumns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('exam_report')")
            #expect(!examColumns.contains { $0.contains("critical") || $0.contains("triage") }, "\(examColumns)")
            let diagnosisTargets = Set(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(diagnosis)").map { $0["table"] as String })
            #expect(diagnosisTargets == ["patient_profile", "encounter", "health_problem", "document_file"], "diagnosis 不得 FK 到 code_concept/ICD 字典")
        }
    }
}
#endif
