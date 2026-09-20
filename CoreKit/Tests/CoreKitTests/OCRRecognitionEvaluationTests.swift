#if os(macOS)
// linux-blind: （平台守卫：macOS 专用 CoreText/Vision 渲染评测） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import Testing
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Domain
@testable import Infrastructure

/// Stage 0：识别层基线（macOS Vision）。
/// 双轨（round3 裁定 C4）：
/// - **合成轨**：金样 JSON（Fixtures/extraction/）经 CoreText 运行时渲染成图后跑 Vision——
///   金样定义文件即硬哨兵（缺失/解码失败即红），无需提交二进制图；
/// - **真实轨**：`Fixtures/ocr/real/`（gitignore，业主脱敏单据）在场才跑，
///   `@Test(.enabled(if:))` 真跳过（不伪绿）；成对完整性（有图无 .lines.txt）无论跳过与否都硬红。
/// 行级 CER 按行号对齐；多出/缺失整行按 max(reference, hypothesis) 行长计错（round3 修正计权）。
@Suite("SU-OCR0-EVAL · 识别层基线（macOS Vision 双轨）", .serialized)
struct OCRRecognitionEvaluationTests {

    // MARK: - 合成轨：金样渲染

    private static var extractionDir: URL? {
        for p in ["Tests/CoreKitTests/Fixtures/extraction", "CoreKit/Tests/CoreKitTests/Fixtures/extraction"] {
            let url = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static var realDir: URL? {
        let file = URL(fileURLWithPath: #filePath)
        let dir = file.deletingLastPathComponent().appendingPathComponent("Fixtures/ocr/real")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    static var hasRealSamples: Bool {
        guard let dir = realDir else { return false }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []   // try?-ok: 目录读取失败按无样本跳过
        return items.contains { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    }

    /// 金样 lines → PNG（CoreText 渲染，字体/字号/行高钉版：PingFang SC 24pt / 32pt 行高 / 20pt 边距）。
    static func renderPNG(lines: [String]) -> Data? {
        guard !lines.isEmpty else { return nil }
        // CTFontCreateWithName 返回非可选（缺字体时 CoreText 自行回退系统字体）。
        let font = CTFontCreateWithName("PingFang SC" as CFString, 24, nil)
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        let drawn: [(line: CTLine, width: CGFloat)] = lines.map { text in
            let attributed = CFAttributedStringCreate(nil, text as CFString, attrs)!
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return (line, width)
        }
        let lineHeight: CGFloat = 32
        let margin: CGFloat = 20
        let width = Int((drawn.map(\.width).max() ?? 100) + margin * 2)
        let height = Int(CGFloat(lines.count) * lineHeight + margin * 2)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.textMatrix = .identity
        for (index, item) in drawn.enumerated() {
            let y = CGFloat(height) - margin - CGFloat(index) * lineHeight - 24
            ctx.textPosition = CGPoint(x: margin, y: y)
            CTLineDraw(item.line, ctx)
        }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func goldenCards() -> [(name: String, lines: [String])] {
        guard let dir = extractionDir else { return [] }
        let decoder = JSONDecoder()
        struct Card: Decodable { let lines: [String] }
        return ["prescription_golden", "lab_golden", "encounter_golden"].compactMap { name in
            let url = dir.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: url),  // try?-ok: 金样缺失按 nil（基线断言处红）
                  let card = try? decoder.decode(Card.self, from: data) else { return nil }  // try?-ok: 解码失败按 nil
            return (name, card.lines)
        }
    }

    /// 行级 CER 单源 Domain `CharacterErrorRate.lineAligned`（round4 P-9：测试不再持有生产语义副本）。
    static func lineCER(reference: [String], hypothesis: [String]) -> Double {
        CharacterErrorRate.lineAligned(reference: reference, hypothesis: hypothesis)
    }

    // MARK: - 合成轨：金样渲染图跑 Vision（硬哨兵）

    @Test func syntheticRenderedGoldensRecognizeBelowSanityCER() async throws {
        let cards = Self.goldenCards()
        #expect(cards.count == 3, "合成轨金样定义缺失（应为 prescription/lab/encounter 三份）——硬哨兵")
        guard cards.count == 3 else { return }
        let recognizer = VisionImageRecognizer()
        var sum = 0.0
        for card in cards {
            let png = try #require(Self.renderPNG(lines: card.lines), "\(card.name) 渲染失败")
            let recognition = try await recognizer.recognize(png)
            let cer = Self.lineCER(reference: card.lines, hypothesis: recognition.lines)
            print("[ocr-eval] \(card.name) macOS-Vision CER=\(String(format: "%.4f", cer)) ref=\(card.lines.count) hyp=\(recognition.lines.count)")
            sum += cer
        }
        let mean = sum / Double(cards.count)
        print("[ocr-eval] synthetic mean CER=\(String(format: "%.4f", mean))")
        #expect(mean < 0.5, "合成轨 Vision 基线 CER 异常高（\(mean)），检查渲染或行对齐")
    }

    // MARK: - 真实轨：脱敏单据（在场才跑，真跳过）

    private static func realSamples() throws -> [(id: String, image: Data, lines: [String])] {
        guard let dir = realDir else { return [] }
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return try items.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.map { img in
            let id = img.deletingPathExtension().lastPathComponent
            let txt = dir.appendingPathComponent("\(id).lines.txt")
            let lines = try String(contentsOf: txt, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
            return (id, try Data(contentsOf: img), lines)
        }
    }

    @Test func realFixturesArePaired() {
        guard let dir = Self.realDir else { return }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []   // try?-ok: 目录读取失败按无夹具处理
        let images = items.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        for img in images {
            let id = img.deletingPathExtension().lastPathComponent
            let txt = dir.appendingPathComponent("\(id).lines.txt")
            #expect(FileManager.default.fileExists(atPath: txt.path), "真实夹具 \(id) 缺 .lines.txt（成对完整性，跳过与否都硬红）")
        }
    }

    @Test(.enabled(if: hasRealSamples))
    func realVisionBaselineCER() async throws {
        let samples = try Self.realSamples()
        #expect(!samples.isEmpty)
        let recognizer = VisionImageRecognizer()
        var sum = 0.0
        for s in samples {
            let recognition = try await recognizer.recognize(s.image)
            let cer = Self.lineCER(reference: s.lines, hypothesis: recognition.lines)
            print("[ocr-eval] real \(s.id) macOS-Vision CER=\(String(format: "%.4f", cer)) ref=\(s.lines.count) hyp=\(recognition.lines.count)")
            sum += cer
        }
        let mean = sum / Double(samples.count)
        print("[ocr-eval] real mean CER=\(String(format: "%.4f", mean)) over \(samples.count)")
        #expect(mean < 0.5, "真实轨 Vision 基线 CER 异常高（\(mean)），检查夹具行对齐")
    }
}
#endif
