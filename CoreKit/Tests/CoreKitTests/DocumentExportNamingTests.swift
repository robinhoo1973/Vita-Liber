import Foundation
import Testing
@testable import Domain

/// 导出副本命名金样（2026-10-27 存储边界委员会 D4/E3 验收：净化/截断/去重/回落）。
/// 纯 Domain，Linux 也真跑。
@Suite("SU-M2-DOCEXPORT · 导出副本命名")
struct DocumentExportNamingTests {
    private func confirmed(_ key: String, _ value: String) -> FieldDraft {
        FieldDraft(key: key, value: value, grade: .userConfirmed)
    }

    // MARK: - 净化不变量（I4）

    @Test("路径穿越/分隔符/控制符/双向覆盖符全部清除")
    func sanitizeNeutralizesHostileInput() {
        #expect(!DocumentExportNaming.sanitizeComponent("../../etc/passwd").contains("/"))
        #expect(!DocumentExportNaming.sanitizeComponent("a\\b:c").contains("\\"))
        #expect(!DocumentExportNaming.sanitizeComponent("a\\b:c").contains(":"))
        #expect(DocumentExportNaming.sanitizeComponent("\u{202E}evil\u{2066}x") == "evilx")
        #expect(DocumentExportNaming.sanitizeComponent("nul\u{0}byte") == "nulbyte")
        #expect(DocumentExportNaming.sanitizeComponent("..") == "")
        #expect(DocumentExportNaming.sanitizeComponent(".") == "")
        #expect(DocumentExportNaming.sanitizeComponent("   ") == "")
        #expect(!DocumentExportNaming.sanitizeComponent(".hidden").hasPrefix("."))
        #expect(DocumentExportNaming.sanitizeComponent("name. ") == "name")
    }

    @Test("Windows 保留名前缀下划线")
    func sanitizeReservedNames() {
        #expect(DocumentExportNaming.sanitizeComponent("CON") == "_CON")
        #expect(DocumentExportNaming.sanitizeComponent("com1") == "_com1")
    }

    @Test("CJK 与常用标点保留、NFD 输入归一、幂等")
    func sanitizeUnicodeAndIdempotence() {
        let cjk = "病历-检验报告(2026)·协和"
        #expect(DocumentExportNaming.sanitizeComponent(cjk) == cjk)
        let nfd = "e\u{0301}cole"   // é 分解形态
        let once = DocumentExportNaming.sanitizeComponent(nfd)
        #expect(once == "école")
        #expect(DocumentExportNaming.sanitizeComponent(once) == once)
        for raw in ["a--b", " x ", "报告  单", "CON", "..a..", "x/y:z"] {
            let once = DocumentExportNaming.sanitizeComponent(raw)
            #expect(DocumentExportNaming.sanitizeComponent(once) == once,
                    "净化必须幂等：\(raw) → \(once)")
        }
    }

    @Test("超长按 UTF-8 字节截断并附稳定哈希后缀，且不超上限")
    func sanitizeTruncatesByUTF8Bytes() {
        let long = String(repeating: "慢病随访报告", count: 60)
        let out = DocumentExportNaming.sanitizeComponent(long)
        #expect(out.utf8.count <= DocumentExportNaming.maxComponentBytes)
        #expect(out.utf8.count > DocumentExportNaming.maxComponentBytes - 40)
        // 确定性：同一输入两次输出一致
        #expect(out == DocumentExportNaming.sanitizeComponent(long))
        // 不同输入不同后缀（抽样）
        let other = String(repeating: "门诊病历", count: 60)
        #expect(DocumentExportNaming.sanitizeComponent(other) != out)
    }

    // MARK: - 命名模板

    @Test("确认标题优先且来源标注")
    func titleTakesPrecedence() {
        let name = DocumentExportNaming.name(.init(
            preferredTitle: "2026-09-12 · 协和医院 · 门诊病历",
            preferredTitleSource: .user,
            fields: [confirmed("hospital", "协和医院")],
            cardKind: "encounter",
            dayText: "2026-09-12",
            documentID: UUID(),
            fileExtension: "PDF"))
        #expect(name.fileName.hasSuffix(".pdf"))
        #expect(name.stem.contains("协和医院"))
        #expect(name.source == .user)
    }

    @Test("无标题：卡类型-已确认首值-日期")
    func templateFromConfirmedFields() {
        let name = DocumentExportNaming.name(.init(
            fields: [confirmed("hospital", "协和医院"), confirmed("drug_name", "阿司匹林肠溶片")],
            cardKind: "prescription",
            dayText: "2026-10-01",
            documentID: UUID(),
            fileExtension: "jpg"))
        #expect(name.stem == "处方笺-协和医院-2026-10-01")
        #expect(name.fileName == "处方笺-协和医院-2026-10-01.jpg")
        #expect(name.source == .auto)
    }

    @Test("D 级未确认字段绝不入名")
    func unconfirmedFieldsExcluded() {
        let unconfirmed = FieldDraft(key: "hospital", value: "未确认医院", grade: .ocrUnconfirmed)
        let name = DocumentExportNaming.name(.init(
            fields: [unconfirmed],
            cardKind: "encounter",
            dayText: "2026-10-01",
            documentID: UUID()))
        #expect(!name.stem.contains("未确认医院"))
        #expect(name.source == .fallback)
    }

    @Test("无素材回落：类型-日期-短ID")
    func fallbackShape() {
        let id = UUID(uuidString: "ABCDEF00-1234-5678-9ABC-DEF012345678")!
        let name = DocumentExportNaming.name(.init(
            cardKind: "encounter",
            dayText: "2026-10-01",
            documentID: id))
        #expect(name.stem == "门诊病历-2026-10-01-abcdef00")
        #expect(name.source == .fallback)
        #expect(name.fileName == name.stem)
    }

    @Test("字段日期优先于调用方日期文本（无首值 → 回落形态含短ID）")
    func fieldDateWins() {
        let id = UUID(uuidString: "ABCDEF00-1234-5678-9ABC-DEF012345678")!
        let name = DocumentExportNaming.name(.init(
            fields: [],
            cardKind: "metric_sample",
            dayText: "2026-10-01",
            documentID: id))
        #expect(name.stem == "检验报告-2026-10-01-abcdef00")
        #expect(name.source == .fallback)
    }

    @Test("非法扩展名丢弃、大小写归一")
    func extensionValidation() {
        let base = DocumentExportNaming.Request(
            preferredTitle: "报告",
            documentID: UUID(),
            fileExtension: "..j/pg")
        #expect(DocumentExportNaming.name(base).fileName == "报告")
        let upper = DocumentExportNaming.Request(
            preferredTitle: "报告", documentID: UUID(), fileExtension: "PDF")
        #expect(DocumentExportNaming.name(upper).fileName == "报告.pdf")
    }

    // MARK: - 去重与目录

    @Test("同目录重名消解 -2/-3，大小写与规范化不敏感")
    func dedupeStems() {
        let existing: Set<String> = ["报告", DocumentExportNaming.normalizeKey("ＲＥＰＯＲＴ")]
        #expect(DocumentExportNaming.deduplicatedStem("报告", existing: existing) == "报告-2")
        #expect(DocumentExportNaming.deduplicatedStem("新名", existing: existing) == "新名")
        #expect(DocumentExportNaming.deduplicatedStem("报告-2", existing: existing) == "报告-2")
    }

    @Test("会话目录：净化标题+短ID；空标题回落未命名会话")
    func directoryNames() {
        let id = UUID(uuidString: "ABCDEF00-1234-5678-9ABC-DEF012345678")!
        #expect(DocumentExportNaming.directoryName(conversationTitle: "体检报告 2026", conversationID: id)
                == "体检报告 2026-abcdef")
        #expect(DocumentExportNaming.directoryName(conversationTitle: "  ", conversationID: id)
                == "未命名会话-abcdef")
        #expect(DocumentExportNaming.directoryName(conversationTitle: "../../x", conversationID: id)
                == "x-abcdef")
        #expect(DocumentExportNaming.directoryName(conversationTitle: "a b", conversationID: id,
                                                   taken: [DocumentExportNaming.normalizeKey("a b-abcdef")])
                == "a b-abcdef-2")
        // 业主 2026-10-30：日期时间前缀（「文件」App 按时间排序）。
        #expect(DocumentExportNaming.directoryName(conversationTitle: "体检报告", conversationID: id,
                                                   datePrefix: "20261030-1435")
                == "20261030-1435-体检报告-abcdef")
        #expect(DocumentExportNaming.directoryName(conversationTitle: "  ", conversationID: id,
                                                   datePrefix: "20261030-1435")
                == "20261030-1435-未命名会话-abcdef")
        #expect(DocumentExportNaming.directoryName(conversationTitle: "x", conversationID: id,
                                                   datePrefix: "  ")
                == "x-abcdef")
    }
}
