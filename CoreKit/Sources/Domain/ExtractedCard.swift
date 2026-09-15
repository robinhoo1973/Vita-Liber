import Foundation

/// 子项目 E2（2026-09-14 实施计划 Task E2 / design §4.5）：`CardExtractionEngine` 三轨共同的输出值对象。
/// 全部 Codable——随 `PageAnalysis` 进 `ocr_review` 快照；全部产物恒 D 级（BR-003），锚点回指原文行，
/// 模型自评分**不**进本结构（`confidence` = min(页 OCR 置信, 0.6) 由注册表/适配器统一赋值）。

/// 产出轨（design §5.1）：T1 Foundation Models / T2 本机文本 LLM（子项目 F）/ T3 规则。
public enum ExtractionTrack: String, Codable, Sendable, CaseIterable {
    case foundationModels, localLLM, rules
}

/// 降级原因（UI 诚实标注，design §5.5；`none` = 未降级）。
public enum DegradedReason: String, Codable, Sendable {
    case none, unavailable, notAuthorized, timeout, modelBusy, engineError, lowGrounding, notInstalled, memoryPressure
}

/// 原文锚点：页 / 行 / 块 / 行身份 + 行内 UTF-16 范围（grounding 校验后回填；`0..<0` = 尚未定位）。
public struct TextAnchor: Codable, Sendable, Equatable {
    public var pageIndex: Int, lineIndex: Int, blockId: String?, rowId: String?, utf16Range: Range<Int>
    public init(pageIndex: Int, lineIndex: Int, blockId: String?, rowId: String?, utf16Range: Range<Int>) {
        self.pageIndex = pageIndex; self.lineIndex = lineIndex; self.blockId = blockId
        self.rowId = rowId; self.utf16Range = utf16Range
    }
}

/// 已锚定的值：`value` = 印刷原文（或模型逐字抄录，经 grounding 定位）；`normalized` 仅枚举 canonical；
/// `continuation` = 多段值（换行拼接）的后续段锚点，与 `value` 的 `\n` 分段一一对应。
public struct GroundedValue: Codable, Sendable, Equatable {
    public var value: String, unit: String?, normalized: String?, anchor: TextAnchor, continuation: [TextAnchor], confidence: Double
    public init(value: String, unit: String? = nil, normalized: String? = nil, anchor: TextAnchor,
                continuation: [TextAnchor] = [], confidence: Double) {
        self.value = value; self.unit = unit; self.normalized = normalized
        self.anchor = anchor; self.continuation = continuation; self.confidence = confidence
    }
}

public struct ExtractionProvenance: Codable, Sendable, Equatable {
    public var track: ExtractionTrack, specVersion: Int, modelId: String?, durationMs: Int
    public init(track: ExtractionTrack, specVersion: Int, modelId: String?, durationMs: Int) {
        self.track = track; self.specVersion = specVersion; self.modelId = modelId; self.durationMs = durationMs
    }
}

public struct ExtractionDiagnostics: Codable, Sendable, Equatable {
    /// 卡级主轨 = 首个有锚定产出的轨；`mixedTracks` 时 UI 追加字段级角标（design §5.5）。
    public var track: ExtractionTrack
    public var degradedReason: DegradedReason
    public var droppedUngrounded: Int
    public var timedOutRegions: Int
    public var retries: Int
    public var mixedTracks: Bool
    /// 逐区域产出轨（`ExtractionRegion.id` → 有锚定产出的轨，按贡献顺序）；零产出的轨不登记，不冒充产出。
    public var regionTracks: [String: [ExtractionTrack]]
    public init(track: ExtractionTrack, degradedReason: DegradedReason = .none, droppedUngrounded: Int = 0,
                timedOutRegions: Int = 0, retries: Int = 0, mixedTracks: Bool = false, regionTracks: [String: [ExtractionTrack]] = [:]) {
        self.track = track; self.degradedReason = degradedReason; self.droppedUngrounded = droppedUngrounded
        self.timedOutRegions = timedOutRegions; self.retries = retries; self.mixedTracks = mixedTracks
        self.regionTracks = regionTracks
    }
}

/// 标题来源（E5）：`.detected` = 引擎自动生成，`.userEdited` = 用户在确认页手动修改。
public enum TitleSource: String, Codable, Sendable { case detected, userEdited }

/// 一页一卡类的抽取产物：共享字段 + 多行 + 续表提示（上一页共享字段，E3 `ContinuationRules` 填充）。
public struct ExtractedCard: Codable, Sendable, Equatable {
    public let kind: String, pageIndex: Int
    public var shared: [String: GroundedValue], rows: [[String: GroundedValue]], continuationHint: [String: GroundedValue]
    public var provenance: ExtractionProvenance, diagnostics: ExtractionDiagnostics
    /// E5：文档标题来源（`DocumentNaming.suggestTitle` 产出 → `.detected`；用户编辑后 → `.userEdited`）。
    public var titleSource: TitleSource?
    public init(kind: String, pageIndex: Int, shared: [String: GroundedValue], rows: [[String: GroundedValue]],
                continuationHint: [String: GroundedValue] = [:], provenance: ExtractionProvenance, diagnostics: ExtractionDiagnostics,
                titleSource: TitleSource? = nil) {
        self.kind = kind; self.pageIndex = pageIndex; self.shared = shared; self.rows = rows
        self.continuationHint = continuationHint; self.provenance = provenance; self.diagnostics = diagnostics
        self.titleSource = titleSource
    }
}

// MARK: - 区域（引擎输入）

/// 区域类型：表头（首个多列行之前）/ 表格（结构化表或连续多列行）/ 段落（表格之后的单列行）。
public enum RegionKind: String, Codable, Sendable { case header, table, paragraph }

public struct ExtractionCell: Codable, Sendable, Equatable {
    public var text: String, lineIndices: [Int], columnIndex: Int
    public init(text: String, lineIndices: [Int], columnIndex: Int) {
        self.text = text; self.lineIndices = lineIndices; self.columnIndex = columnIndex
    }
}

public struct ExtractionRow: Codable, Sendable, Equatable {
    public var id: String, cells: [ExtractionCell]
    public init(id: String, cells: [ExtractionCell]) { self.id = id; self.cells = cells }
    public var text: String { cells.map(\.text).joined(separator: " ") }
    public var lineIndices: [Int] { cells.flatMap(\.lineIndices) }
}

public struct ExtractionRegion: Codable, Sendable, Equatable {
    public var pageIndex: Int, id: String, kind: RegionKind, columnHeader: [String]?, rows: [ExtractionRow]
    public init(pageIndex: Int, id: String, kind: RegionKind, columnHeader: [String]?, rows: [ExtractionRow]) {
        self.pageIndex = pageIndex; self.id = id; self.kind = kind; self.columnHeader = columnHeader; self.rows = rows
    }
}

// MARK: - 抽取请求与原始结果（结构轮 2026-09-15：自 Protocols 迁入——抽取模型值对象单一归属 Domain）

/// 一页一次抽取请求：版面区域 + 候选 spec；`pageBudget` = 单页生成轨总预算（design §5.6，nil = 不限），
/// 耗尽后剩余区域只走规则轨；`allowsGenerativeProcessing == false` 时 T1/T2 一律不调用（授权门，design §5.2）。
public struct ExtractionRequest: Sendable {
    public var pageIndex: Int, lines: [String], regions: [ExtractionRegion], specs: [ExtractionSpec]
    public var allowsGenerativeProcessing: Bool, pageConfidence: Double, pageBudget: Duration?
    public init(pageIndex: Int, lines: [String], regions: [ExtractionRegion], specs: [ExtractionSpec],
                allowsGenerativeProcessing: Bool, pageConfidence: Double, pageBudget: Duration? = nil) {
        self.pageIndex = pageIndex; self.lines = lines; self.regions = regions; self.specs = specs
        self.allowsGenerativeProcessing = allowsGenerativeProcessing; self.pageConfidence = pageConfidence; self.pageBudget = pageBudget
    }
}

/// 单区域原始结果（未 grounding）。
public struct RegionExtraction: Sendable, Equatable {
    public var shared: [String: GroundedValue], rows: [[String: GroundedValue]]
    public init(shared: [String: GroundedValue], rows: [[String: GroundedValue]]) { self.shared = shared; self.rows = rows }
    public var isEmpty: Bool { shared.isEmpty && rows.allSatisfy(\.isEmpty) }
    public var valueCount: Int { shared.count + rows.reduce(0) { $0 + $1.count } }
}

extension PageLayout {
    /// 表格 → `.table`（行 = `TableRow`，格按 columnIndex 排序）；表外块几何聚行：首个多列行前 → `.header`；
    /// 连续 ≥2 列行段 → 合成 `.table`；其余 → `.paragraph`。按首行号排序。
    public func extractionRegions(pageIndex: Int) -> [ExtractionRegion] {
        var regions: [ExtractionRegion] = []
        let covered = Set(tables.flatMap { $0.rows.flatMap { $0.cells.flatMap(\.lineIndices) } }
                          + tables.flatMap { $0.header?.cells.flatMap(\.lineIndices) ?? [] })
        for table in tables {
            regions.append(ExtractionRegion(
                pageIndex: pageIndex, id: table.id, kind: .table, columnHeader: table.header?.cells.sorted { $0.columnIndex < $1.columnIndex }.map(\.text),
                rows: table.rows.enumerated().map { i, row in
                    ExtractionRow(id: "\(table.id)r\(i)", cells: row.cells.sorted { $0.columnIndex < $1.columnIndex }
                        .map { ExtractionCell(text: $0.text, lineIndices: $0.lineIndices, columnIndex: $0.columnIndex) })
                }))
        }
        var current: [ExtractionRow] = [], kind: RegionKind = .header, seenTable = false, geometric = 0
        func flush() {
            guard !current.isEmpty else { return }
            regions.append(ExtractionRegion(pageIndex: pageIndex, id: "g\(geometric)", kind: kind, columnHeader: nil, rows: current))
            geometric += 1; current = []
        }
        for row in LayoutRowBuilder.rows(from: blocks.filter { !covered.contains($0.lineIndex) }) {
            // 结构化表格（iOS 26）之下的单列行同样是「表后」段落：按几何位置判定（行中线在表格底缘之下）。
            if tables.contains(where: { $0.bbox.maxY <= row.bbox.midY }) { seenTable = true }
            let next: RegionKind = row.cells.count >= 2 ? .table : (seenTable ? .paragraph : .header)
            if next != kind { flush(); kind = next }
            if next == .table { seenTable = true }
            current.append(ExtractionRow(id: row.id, cells: row.cells.map {
                ExtractionCell(text: $0.text, lineIndices: [$0.lineIndex], columnIndex: $0.columnIndex)
            }))
        }
        flush()
        return regions.sorted { ($0.rows.first?.lineIndices.first ?? 0) < ($1.rows.first?.lineIndices.first ?? 0) }
    }
}
