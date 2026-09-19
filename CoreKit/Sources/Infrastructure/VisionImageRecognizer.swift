// 平台守卫镜像 Package.swift（ERR#8 纪律）：Vision 仅 Apple 平台可用。
#if os(iOS) || os(macOS)
// linux-blind: Vision OCR —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import Vision
import Domain
import Protocols

/// FR12.11 的生产实现：Vision `VNRecognizeTextRequest`（iOS 16 路径）+
/// iOS 26 `RecognizeDocumentsRequest`（结构化路径，见 `DocumentLayoutBridge`）。
///
/// - **端上识别**（离线零网络——隐私红线延伸）；
/// - 零落盘：入参是 `Data`、出参是文本行 + 版面，中间不产生任何文件；
/// - **只负责识别**：D 级待确认判定在 Domain `ImageInputRules`，
///   本类绝不越权把识别结果标成确认。
/// - FR5.5 版面（子项目 E1）：两条路径都保留块 bbox（Vision 左下原点 → Domain 左上原点）；
///   表格/段落只有 iOS 26 结构化路径给出，iOS 16 路径由 Domain `LayoutRowBuilder` 几何聚行。
public final class VisionImageRecognizer: ImageTextRecognizing, @unchecked Sendable {
    public init() {}

    public func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition {
        // 第四轮全仓审查效率修复（5WHY）：函数体无 actor 跳转，从 MainActor
        // （OCRPipeline ← DocumentsState 导入流）await 进来时全分辨率
        // .accurate 识别在主线程同步执行，逐页 PDF 连续卡 UI。detached 跳出
        // 主线程；VN handler/request 非 Sendable，全部在闭包内构造不外逃。
        //
        // iOS 26 结构化路径先行：抛错 / 无文档 / 零文本行 → 一律回落 VN 路径
        // （design §7：RecognizeDocumentsRequest 仅 iOS 26+，退化 = 几何聚行）。
        if #available(iOS 26, macOS 26, *) {
            do {
                if let structured = try await Task.detached(priority: .userInitiated, operation: {
                    try await DocumentLayoutBridge.recognize(imageData)
                }).value {
                    return structured
                }
            } catch {
                // 结构化路径任何失败都不是终态——VN 路径是 iOS 16 起的参考行为。
            }
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.performRecognition(imageData)
        }.value
    }

    /// iOS 16 路径：`VNRecognizeTextRequest` 行识别，保留每行 boundingBox。
    private static func performRecognition(_ imageData: Data) throws -> ImageInputRules.Recognition {
        // VNImageRequestHandler(data:) 在 iOS 18 SDK 是非 failable 初始化器，
        // `guard let` 的 optional 绑定直接编译失败（CI Xcode 16 报
        // 「initializer for conditional binding must have Optional type」；
        // 本地 Linux 不编译此文件故未暴露——ERR#29 结构性盲区）。
        let handler = VNImageRequestHandler(data: imageData)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // FR5.x（OCR 语言契约）：默认识别简体/繁体/英文三语——显式列出
        // ["zh-Hans","zh-Hant","en-US"]，Vision 按候选语言逐块选最优模型。
        // 不得置空依赖自动检测：空数组在准确级下会退回设备主语言优先的
        // 弱检测，繁体/英文混排文档易被简体模型误识（药/藥 类字形错别）。
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        do {
            try handler.perform([request])
        } catch {
            throw RecognizeError.engineFailed
        }
        guard let observations = request.results else {
            return ImageInputRules.Recognition(lines: [], confidence: 0, layout: PageLayout(blocks: []))
        }
        var lines: [String] = []
        var blocks: [TextBlock] = []
        var confidenceSum = 0.0
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            // VNRectangleObservation.boundingBox：归一化、左下原点 → Domain 左上原点。
            let box = obs.boundingBox
            blocks.append(TextBlock(text: candidate.string,
                                    bbox: LayoutRect(x: Double(box.minX), y: 1 - Double(box.maxY),
                                                     width: Double(box.width), height: Double(box.height)),
                                    lineIndex: lines.count, confidence: Double(candidate.confidence)))
            lines.append(candidate.string)
            confidenceSum += Double(candidate.confidence)
        }
        let confidence = lines.isEmpty ? 0 : confidenceSum / Double(lines.count)
        return ImageInputRules.Recognition(lines: lines, confidence: confidence, layout: PageLayout(blocks: blocks))
    }

    public enum RecognizeError: Error, LocalizedError {
        case engineFailed
        public var errorDescription: String? { "图片识别失败: \(self)" }
    }
}

/// iOS 26 结构化路径（Vision Swift API）：单次 `RecognizeDocumentsRequest` 同时给出
/// 文本行、表格（单元格）与段落。**刻意独立成小类型**：本机（Linux）无 iOS 26 SDK 无法核编，
/// 成员名以 Apple 文档（2026-09-14 核实）为准——`DocumentObservation.Container.{text.lines,tables,paragraphs}`、
/// `Container.Table.{rows,boundingRegion}`、`Table.Cell.{content,columnRange}`、
/// `RecognizedTextObservation.{transcript,confidence,boundingRegion}`、`NormalizedRegion.boundingBox`
/// （`NormalizedRect.origin` 为左下角）。CI 若报编译错，只会落在本类型内。
@available(iOS 26, macOS 26, *)
private enum DocumentLayoutBridge {
    /// 抛错由调用方吞掉回落 VN；无文档或零文本行 → nil 同样回落。
    static func recognize(_ imageData: Data) async throws -> ImageInputRules.Recognition? {
        var request = RecognizeDocumentsRequest()
        // 语言契约与 VN 路径一致（简/繁/英三语显式列出）。
        request.textRecognitionOptions.recognitionLanguages =
            ["zh-Hans", "zh-Hant", "en-US"].map { Locale.Language(identifier: $0) }
        request.textRecognitionOptions.useLanguageCorrection = true
        let observations = try await request.perform(on: imageData, orientation: nil)
        guard let document = observations.first?.document else { return nil }

        var lines: [String] = []
        var blocks: [TextBlock] = []
        var confidenceSum = 0.0
        for line in document.text.lines {
            let text = line.transcript
            blocks.append(TextBlock(text: text, bbox: rect(line.boundingRegion),
                                    lineIndex: lines.count, confidence: Double(line.confidence)))
            lines.append(text)
            confidenceSum += Double(line.confidence)
        }
        guard !lines.isEmpty else { return nil }

        // 块中心落在区域内 → 归属该区域（表格格 / 段落）。
        func lineIndices(in region: LayoutRect) -> [Int] {
            blocks.filter { region.contains(x: $0.bbox.midX, y: $0.bbox.midY) }.map(\.lineIndex)
        }
        let tables = document.tables.enumerated().map { index, table -> TableRegion in
            let rows = table.rows.map { cells -> TableRow in
                TableRow(cells: cells.map { cell -> TableCell in
                    let cellRect = rect(cell.content.boundingRegion)
                    return TableCell(text: cell.content.text.transcript, bbox: cellRect,
                                     columnIndex: cell.columnRange.lowerBound,
                                     lineIndices: lineIndices(in: cellRect))
                })
            }
            // 表头判定在 Domain（E3 按列别名），识别层恒 nil。
            return TableRegion(id: "t\(index)", bbox: rect(table.boundingRegion), rows: rows, header: nil)
        }
        let paragraphs = document.paragraphs.map { paragraph -> Paragraph in
            let paragraphRect = rect(paragraph.boundingRegion)
            return Paragraph(text: paragraph.transcript, bbox: paragraphRect,
                             lineIndices: lineIndices(in: paragraphRect))
        }
        return ImageInputRules.Recognition(lines: lines, confidence: confidenceSum / Double(lines.count),
                                           layout: PageLayout(blocks: blocks, tables: tables, paragraphs: paragraphs))
    }

    /// Vision `NormalizedRegion`（多边形）→ 外接矩形；左下原点 → Domain 左上原点。
    private static func rect(_ region: NormalizedRegion) -> LayoutRect {
        let box = region.boundingBox
        return LayoutRect(x: Double(box.origin.x),
                          y: 1 - Double(box.origin.y) - Double(box.height),
                          width: Double(box.width), height: Double(box.height))
    }
}
#endif
