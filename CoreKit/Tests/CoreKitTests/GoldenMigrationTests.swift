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
            for _ in 0..<20 { g.addTask { await gate.enter { await c.inc() } } }
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
        var attempt = 0
        var firstErrorReachedCaller = false
        do {
            try await gate.enter {
                attempt += 1
                if attempt == 1 { throw Boom() }
            }
        } catch {
            firstErrorReachedCaller = true  // 第一次失败，错误到达发起方
        }
        #expect(firstErrorReachedCaller)
        #expect(await gate.currentState == .idle)          // 失败不得置 ready
        try await gate.enter { attempt += 1 }              // 重试走 idle 分支
        #expect(await gate.currentState == .ready)
        #expect(attempt == 2)
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

        // 应用 v6 迁移步骤（幂等：可整步重放）
        try dbQueue.write { db in
            for step in SchemaMigrations.pending(from: 5) {
                for statement in SchemaMigrations.statements(step.sql) {
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

        // 幂等重放：同一步再跑一遍不炸、结果不变
        try dbQueue.write { db in
            for step in SchemaMigrations.pending(from: 5) {
                for statement in SchemaMigrations.statements(step.sql) {
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
#endif
