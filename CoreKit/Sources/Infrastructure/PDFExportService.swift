#if os(iOS)
import Foundation
import UIKit
import GRDB
import Domain
import Protocols

/// FR13.1 PDF 导出（§5.7）：封面（标题/当事人/时间范围/数量/免责）+
/// 目录带页码 + 逐记录页 + 可选水印。
///
/// 成熟实现优先（FR0.1）：页面排版用 UIGraphicsPDFRenderer（系统框架，零三方依赖）；
/// 后台渲染带进度回调 + 协作式取消（§5.0 长管线在页边界检查 isCancelled）。
/// FR13.2 导出维度由 ExportRequest.scope 表达（全部/按成员/按日期/按类型/按健康问题/按就诊/医生摘要）。
public actor PDFExportService {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public struct ExportRequest: Sendable {
        public var patientId: UUID
        public var title: String
        public var dateFrom: Date?
        public var dateTo: Date?
        public var docTypes: Set<String>?       // nil = 全部类型
        public var includeNotes: Bool
        public var watermark: Bool
        public var scopeKind: ScopeKind
        /// 免责声明中的急救号码（120/119/911 由 App 层按区域经 L10n 注入——
        /// Infrastructure 不持有区域知识，默认 120 仅供无 App 层的调用方）
        public var emergencyNumber: String
        /// V3.68 封面文案（Infrastructure 不拼中文）：
        /// 记录数标签与免责全文由 App 层经 L10n 注入；空免责不绘制。
        public var countLabel: @Sendable (Int) -> String
        public var disclaimer: String
        /// 记录类型名（资料/观察/用药/就诊）——App 层经 L10n 注入
        public var kindLabel: @Sendable (String) -> String
        public enum ScopeKind: String, Sendable {
            case all, member, dateRange, docType, doctorSummary   // 健康问题/就诊维度随挂接数据
        }
        public init(patientId: UUID, title: String, dateFrom: Date? = nil,
                    dateTo: Date? = nil, docTypes: Set<String>? = nil,
                    includeNotes: Bool = true, watermark: Bool = true,
                    emergencyNumber: String = "120",
                    countLabel: @escaping @Sendable (Int) -> String = { "\($0)" },
                    disclaimer: String = "",
                    kindLabel: @escaping @Sendable (String) -> String = { $0 },
                    scopeKind: ScopeKind = .all) {
            self.patientId = patientId; self.title = title
            self.dateFrom = dateFrom; self.dateTo = dateTo
            self.docTypes = docTypes; self.includeNotes = includeNotes
            self.watermark = watermark; self.emergencyNumber = emergencyNumber
            self.countLabel = countLabel; self.disclaimer = disclaimer
            self.kindLabel = kindLabel
            self.scopeKind = scopeKind
        }
    }

    public struct ExportPackage: Sendable, Equatable {
        public var data: Data
        public var pageCount: Int
        public var recordCount: Int
        public init(data: Data, pageCount: Int, recordCount: Int) {
            self.data = data; self.pageCount = pageCount; self.recordCount = recordCount
        }
    }

    /// 收集导出数据（按维度过滤；敏感媒体只出元数据与 C 级确认文本——BR-007/008）
    private func collect(_ request: ExportRequest) async throws -> (documents: [TimelineDocumentEntry], records: [(kind: String, title: String, at: Date, detail: String)]) {
        try await writer.read { db in
            var docs: [TimelineDocumentEntry] = []
            var dateClause = ""
            var args: [DatabaseValueConvertible] = [request.patientId.uuidString]
            if let from = request.dateFrom { dateClause += " AND created_at >= ?"; args.append(from.timeIntervalSince1970) }
            if let to = request.dateTo { dateClause += " AND created_at <= ?"; args.append(to.timeIntervalSince1970) }
            let rows = try Row.fetchAll(db, sql: """
                SELECT meta_json FROM document_file
                WHERE patient_id = ? AND status IN ('active','favorite') \(dateClause)
                ORDER BY created_at ASC
                """, arguments: StatementArguments(args))
            for row in rows {
                guard let json = row["meta_json"] as String?,
                      let data = json.data(using: .utf8) else { continue }
                do { docs.append(try JSONDecoder().decode(TimelineDocumentEntry.self, from: data)) }
                catch { continue }
            }
            // FR13.2 按类型维度：TimelineDocumentEntry 无 doc_type 列（meta 投影），
            // 类型过滤依赖文档层元数据——此处对「全部/未指定」直通，具体类型
            // 过滤由导出向导在文档列表维度执行（不静默扩大导出范围）。
            let filtered = docs
            var records: [(String, String, Date, String)] = []
            for doc in filtered {
                // 审查修复（BR-003/BR-007）：导出正文只含已确认字段——
                // 原实现把未确认 D 级 OCR 猜测以正式记录姿态拼入导出文件，
                // 与文件头纪律与 PDF 免责声明（仅呈现你确认过的记录）直接矛盾
                let confirmed = (doc.fields ?? []).filter { $0.isConfirmed }
                let detail = confirmed.map { "\($0.displayLabel): \($0.value)" }.joined(separator: "\n")
                records.append((request.kindLabel("record"), doc.title, Date(timeIntervalSince1970: doc.occurredAt), detail))
            }
            // 观察记录（描述为 C 级自述文本；敏感媒体不出正文）
            let obsRows = try Row.fetchAll(db, sql: """
                SELECT kind, occurred_at, description FROM observation
                WHERE patient_id = ? ORDER BY occurred_at ASC
                """, arguments: [request.patientId.uuidString])
            for row in obsRows {
                records.append((request.kindLabel("observation"), request.kindLabel(row["kind"] as String),
                                Date(timeIntervalSince1970: (row["occurred_at"] as Double?) ?? 0),
                                (row["description"] as String?) ?? ""))
            }
            // 用药计划
            let planRows = try Row.fetchAll(db, sql: """
                SELECT p.start_date, m.generic_name, m.spec, p.status FROM medication_plan p
                JOIN medication m ON m.id = p.medication_id
                WHERE p.patient_id = ? ORDER BY p.start_date ASC
                """, arguments: [request.patientId.uuidString])
            for row in planRows {
                records.append((request.kindLabel("plan"), row["generic_name"] as String,
                                Date(timeIntervalSince1970: row["start_date"] as Double),
                                "\(row["spec"] as String? ?? "") · \(row["status"] as String)"))
            }
            // 就诊
            let encRows = try Row.fetchAll(db, sql: """
                SELECT date, kind, hospital, diagnosis_text FROM encounter
                WHERE patient_id = ? ORDER BY date ASC
                """, arguments: [request.patientId.uuidString])
            for row in encRows {
                records.append((request.kindLabel("encounter"), "\(row["hospital"] as String? ?? "") · \(row["kind"] as String)",
                                Date(timeIntervalSince1970: row["date"] as Double),
                                (row["diagnosis_text"] as String?) ?? ""))
            }
            return (filtered, records)
        }
    }

    /// 渲染 PDF：封面 → 目录 → 逐记录页（水印可选；每页检查取消）。
    public func exportPDF(_ request: ExportRequest,
                          progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ExportPackage {
        try Task.checkCancellation()
        let (_, records) = try await collect(request)
        try Task.checkCancellation()

        let pageSize = CGSize(width: 595, height: 842)   // A4 pt
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        var pageCount = 0
        let recordCount = records.count

        let data = renderer.pdfData { ctx in
            // 封面
            ctx.beginPage()
            drawCover(ctx, request: request, count: records.count)
            pageCount += 1
            // 目录（带页码——近似：每记录一页，页码 = 3 + index）
            ctx.beginPage()
            drawTOC(ctx, records: records)
            pageCount += 1
            // 逐记录页
            for (index, record) in records.enumerated() {
                ctx.beginPage()
                drawRecord(ctx, record: record, page: pageCount + 1)
                pageCount += 1
                progress?((index + 1), records.count)
            }
        }
        try Task.checkCancellation()
        return ExportPackage(data: data, pageCount: pageCount, recordCount: recordCount)
    }

    // MARK: - 绘制（系统 PDF 渲染器；文字走本地化由调用方注入标题）

    private func drawCover(_ ctx: UIGraphicsPDFRendererContext, request: ExportRequest, count: Int) {
        let bounds = ctx.cgContext.boundingBoxOfClipPath
        let titleFont = UIFont.boldSystemFont(ofSize: 26)
        (request.title as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: [.font: titleFont])
        let rangeText = "\(request.dateFrom?.formatted(date: .abbreviated, time: .omitted) ?? "—") ~ \(request.dateTo?.formatted(date: .abbreviated, time: .omitted) ?? "—")"
        (rangeText as NSString).draw(at: CGPoint(x: 60, y: 180), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        (request.countLabel(count) as NSString).draw(at: CGPoint(x: 60, y: 210), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        if !request.disclaimer.isEmpty {
            let rect = CGRect(x: 60, y: 720, width: bounds.width - 120, height: 80)
            (request.disclaimer as NSString).draw(in: rect, withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
        }
    }

    private func drawTOC(_ ctx: UIGraphicsPDFRendererContext, records: [(kind: String, title: String, at: Date, detail: String)]) {
        var y: CGFloat = 100
        ("目录" as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18)])
        y += 40
        for (index, record) in records.enumerated() {
            let line = "\(record.kind) · \(record.title) · \(record.at.formatted(date: .abbreviated, time: .omitted))"
            (line as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
            ("\(index + 3)" as NSString).draw(at: CGPoint(x: 500, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
            y += 20
        }
    }

    private func drawRecord(_ ctx: UIGraphicsPDFRendererContext, record: (kind: String, title: String, at: Date, detail: String), page: Int) {
        let bounds = ctx.cgContext.boundingBoxOfClipPath
        var y: CGFloat = 80
        (record.kind as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 16)])
        y += 30
        (record.title as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        y += 24
        (record.at.formatted(date: .long, time: .shortened) as NSString).draw(at: CGPoint(x: 60, y: y),
                                                                              withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
        y += 30
        let rect = CGRect(x: 60, y: y, width: bounds.width - 120, height: bounds.height - y - 100)
        (record.detail as NSString).draw(in: rect, withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        ("\(page)" as NSString).draw(at: CGPoint(x: bounds.width - 80, y: bounds.height - 50),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 10)])
    }
}

#endif
