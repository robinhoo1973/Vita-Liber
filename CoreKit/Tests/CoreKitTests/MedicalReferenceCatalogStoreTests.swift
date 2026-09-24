#if os(iOS) || os(macOS)
import Foundation
import GRDB
import Testing
@testable import Domain
@testable import Infrastructure

/// schema v4 四域参考目录存取的行为钉。夹具库在临时目录用 GRDB 按
/// build_medical_data.sh 的 v4 DDL 现场构建（列名/约束与生产物化一致），
/// 随后以 readonly 模式重新打开——与 App 实际打开 catalog 的路径同形。
@Suite("四域参考目录 Store")
struct MedicalReferenceCatalogStoreTests {

    static let v4Schema = """
    CREATE TABLE catalog_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
    CREATE TABLE hospital (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, code TEXT, name_zh TEXT NOT NULL, short_name TEXT, type_zh TEXT, level_zh TEXT, address TEXT, phone TEXT, admin_area TEXT, depts_json TEXT NOT NULL, aliases_json TEXT NOT NULL, match_status TEXT);
    CREATE TABLE department (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, code TEXT NOT NULL, name_zh TEXT NOT NULL, category_zh TEXT, aliases_json TEXT NOT NULL, match_status TEXT);
    CREATE TABLE diagnosis (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, code TEXT NOT NULL, name_zh TEXT NOT NULL, code_system TEXT NOT NULL, chapter_zh TEXT, aliases_json TEXT NOT NULL, match_status TEXT);
    CREATE TABLE exam_item (region TEXT NOT NULL, source_id TEXT NOT NULL UNIQUE, code TEXT NOT NULL, name_zh TEXT NOT NULL, name_en TEXT, category TEXT, method TEXT, specimen TEXT, unit TEXT, price_ref TEXT, loinc_concept_id TEXT, aliases_json TEXT NOT NULL, match_status TEXT);
    """

    /// 建夹具库：写库灌数据 → 返回路径。
    static func makeFixture() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("medical-catalog.sqlite").path
        var config = Configuration()
        config.readonly = false
        let queue = try DatabaseQueue(path: path, configuration: config)
        try queue.write { db in
            try db.execute(sql: v4Schema)
            try db.execute(sql: "INSERT INTO catalog_meta(key,value) VALUES ('schema_version','4'),('hospital_records','3')")
            try db.execute(sql: """
                INSERT INTO hospital (region, source_id, code, name_zh, short_name, type_zh, level_zh, address, admin_area, depts_json, aliases_json) VALUES
                ('CN','CN:H11010201','H11010201','北京協和醫院(東院)','協和醫院','綜合醫院','三級甲等','北京市東城區帥府園一號','北京市東城區','[{"code":"03.02","name_zh":"心血管內科"}]','["協和醫院","协和医院"]'),
                ('TW','TW:0431010017','0431010017','國立臺灣大學醫學院附設醫院','臺大醫院','綜合醫院','醫學中心','臺北市中正區中山南路7號','臺北市','[]','["臺大醫院"]'),
                ('HK','HK:DP000001','DP000001','明醫醫務中心',NULL,'私家醫院',NULL,'九龍彌敦道26號27樓','香港','[]','[]')
                """)
            try db.execute(sql: """
                INSERT INTO department (region, source_id, code, name_zh, category_zh, aliases_json) VALUES
                ('CN','CN:03','03','內科','臨床一級科目','[]'),
                ('TW','TW:A0200','A0200','內科',NULL,'[]')
                """)
            try db.execute(sql: """
                INSERT INTO diagnosis (region, source_id, code, name_zh, code_system, chapter_zh, aliases_json) VALUES
                ('CN','CN:I21','I21','急性心肌梗死','icd10_cn','循環系統疾病','["急性心梗"]'),
                ('TW','TW:I21','I21','急性心肌梗塞','icd10_cm','循環系統疾病','[]')
                """)
            try db.execute(sql: """
                INSERT INTO exam_item (region, source_id, code, name_zh, name_en, category, specimen, unit, loinc_concept_id, aliases_json) VALUES
                ('CN','CN:250101','250101','血常規檢查','Complete Blood Count','檢驗','全血',NULL,NULL,'["血常规"]'),
                ('TW','TW:08011C','08011C','全套血液檢查','Complete Blood Count','檢驗','全血',NULL,'58410-2','[]')
                """)
        }
        return path
    }

    @Test func hospitalSuggestByAliasAndRegionFilter() async throws {
        let store = try MedicalReferenceCatalogStore(path: try Self.makeFixture())
        let all = try await store.hospitalSuggest(query: "協和", region: nil, limit: 20)
        #expect(all.count == 1)
        #expect(all.first?.nameZh == "北京協和醫院(東院)")
        #expect(all.first?.departments.first?.nameZh == "心血管內科")
        let cnOnly = try await store.hospitalSuggest(query: "臺大", region: "CN", limit: 20)
        #expect(cnOnly.isEmpty)
        let twOnly = try await store.hospitalSuggest(query: "臺大", region: "TW", limit: 20)
        #expect(twOnly.count == 1 && twOnly.first?.region == "TW")
    }

    @Test func departmentListFiltersRegion() async throws {
        let store = try MedicalReferenceCatalogStore(path: try Self.makeFixture())
        let all = try await store.departmentList(region: nil)
        #expect(all.count == 2)
        let cn = try await store.departmentList(region: "CN")
        #expect(cn.count == 1 && cn.first?.code == "03")
    }

    @Test func diagnosisSuggestByCodeSystemAndName() async throws {
        let store = try MedicalReferenceCatalogStore(path: try Self.makeFixture())
        let byCode = try await store.diagnosisSuggest(query: "I21", system: nil, region: nil, limit: 20)
        #expect(byCode.count == 2)
        let byName = try await store.diagnosisSuggest(query: "心梗", system: nil, region: nil, limit: 20)
        #expect(byName.count == 1 && byName.first?.codeSystem == "icd10_cn")
        let cnSystem = try await store.diagnosisSuggest(query: "I21", system: "icd10_cm", region: nil, limit: 20)
        #expect(cnSystem.count == 1 && cnSystem.first?.region == "TW")
    }

    @Test func examSuggestByCategoryAndEnglishAlias() async throws {
        let store = try MedicalReferenceCatalogStore(path: try Self.makeFixture())
        let zh = try await store.examSuggest(query: "血常規", category: "檢驗", region: nil, limit: 20)
        #expect(zh.count == 1 && zh.first?.code == "250101")
        let en = try await store.examSuggest(query: "complete blood", category: nil, region: nil, limit: 20)
        #expect(en.count == 2)
        let loinc = try await store.examSuggest(query: "08011C", category: nil, region: nil, limit: 20)
        #expect(loinc.first?.loincConceptID == "58410-2")
    }

    @Test func likeMetacharactersAreEscaped() async throws {
        let store = try MedicalReferenceCatalogStore(path: try Self.makeFixture())
        let wildcard = try await store.hospitalSuggest(query: "%", region: nil, limit: 20)
        #expect(wildcard.isEmpty) // 未转义时 % 会命中全部 3 行
    }

    @Test func v3CatalogDegradesToEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("v3.sqlite").path
        var config = Configuration()
        config.readonly = false
        let queue = try DatabaseQueue(path: path, configuration: config)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE catalog_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);")
            try db.execute(sql: "INSERT INTO catalog_meta(key,value) VALUES ('schema_version','3');")
        }
        let store = try MedicalReferenceCatalogStore(path: path)
        let version = try await store.catalogSchemaVersion
        #expect(version == 3)
        let hospitalsEmpty = try await store.hospitalSuggest(query: "協和", region: nil, limit: 20).isEmpty
        let departmentsEmpty = try await store.departmentList(region: nil).isEmpty
        let diagnosesEmpty = try await store.diagnosisSuggest(query: "I21", system: nil, region: nil, limit: 20).isEmpty
        let examsEmpty = try await store.examSuggest(query: "血", category: nil, region: nil, limit: 20).isEmpty
        #expect(hospitalsEmpty)
        #expect(departmentsEmpty)
        #expect(diagnosesEmpty)
        #expect(examsEmpty)
    }
}
#endif
