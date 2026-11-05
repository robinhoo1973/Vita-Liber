import Foundation
import Testing
@testable import Domain
@testable import Infrastructure

// binds: SU-M15-OCRTHIRD — CnOCR 第三 OCR 源：logits softmax、逐行 Vision 映射、调试假设
@Suite("SU-M15-OCRTHIRD · CnOCR 第三 OCR 源")
struct CnOCROCRThirdSourceTests {
    @Test func softmaxNormalizesEachTimestepAndKeepsArgmax() throws {
        let logits: [Float] = [0, 1, 2, 0, 0, 0]
        let probabilities = try #require(CTCDecoder.softmax(logits: logits, timesteps: 2, classes: 3))
        #expect(probabilities.count == 6)
        for t in 0..<2 {
            let row = probabilities[(t * 3)..<((t + 1) * 3)]
            #expect(abs(row.reduce(0, +) - 1) < 0.0001)
            #expect(row.max() == probabilities[t * 3 + 2])
        }
        #expect(CTCDecoder.softmax(logits: [0, 1], timesteps: 2, classes: 3) == nil)
    }

    @Test func visionTextMapsOnlySingleLineBlocks() {
        let line1 = PaddleLayoutMerge.Line(text: "血压", bbox: LayoutRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05),
                                            confidence: 0.9)
        let line2 = PaddleLayoutMerge.Line(text: "120/80", bbox: LayoutRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05),
                                            confidence: 0.9)
        let layout = PageLayout(blocks: [
            TextBlock(text: "血压", bbox: LayoutRect(x: 0.09, y: 0.09, width: 0.32, height: 0.07),
                      lineIndex: 0, confidence: 0.9),
            // 一块两行：Vision 合体观察，不能当任何一行的副源。
            TextBlock(text: "120/80\n脉搏 80", bbox: LayoutRect(x: 0.09, y: 0.19, width: 0.32, height: 0.12),
                      lineIndex: 1, confidence: 0.9),
        ])
        let texts = PaddleLayoutMerge.visionTextByLine(paddleLines: [line1, line2], visionLayout: layout)
        #expect(texts[0] == "血压")
        #expect(texts[1] == nil)
        #expect(PaddleLayoutMerge.visionTextByLine(paddleLines: [line1], visionLayout: nil)[0] == nil)
    }

    @Test func debugSegmentsKeepRawPaddleAndAddCnOCR() throws {
        let trace = OCRDebugTrace(
            pageIndex: 2, model: "PP-OCRv6-small@v", modelSHA256: "sha",
            detModel: "det", detModelSHA256: "detsha",
            thirdModel: "CnOCR-doc-densenet_lite_136-gru@2.3", thirdModelSHA256: "thirdsha",
            engine: "e", totalLatencyMs: 1, lines: [
                .init(lineIndex: 0, bbox: [0, 0, 1, 1],
                      visionText: "阿莫西林胶囊", paddleText: "阿莫西林胶囊",
                      rawPaddleText: "阿莫西林胶蛋", cnocrText: "阿莫西林胶囊",
                      visionConfidence: 0.9, paddleConfidence: 0.8,
                      cropWidth: 10, cropHeight: 10, recWidth: 32,
                      timesteps: 8, latencyMs: 2),
            ])
        let segments = RecognitionDebugCapture.ocrSegments(from: trace)
        #expect(segments.count == 1)
        let hypotheses = segments[0].hypotheses
        #expect(hypotheses.map(\.engineID) == ["paddle-ppocrv6-rec", "apple-vision",
                                               "cnocr-doc-densenet-lite-136-gru"])
        #expect(hypotheses[0].text == "阿莫西林胶蛋")
        #expect(hypotheses[2].text == "阿莫西林胶囊")
        #expect(hypotheses[2].modelVersion == "CnOCR-doc-densenet_lite_136-gru@2.3")
    }

    @Test func bundledCatalogDeclaresThirdAsset() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let catalogURL = root.appendingPathComponent("Resources/OCRModels/catalog.json")
        let catalog = try JSONDecoder().decode(OCRModelStore.Catalog.self,
                                               from: Data(contentsOf: catalogURL))
        let third = try #require(catalog.third)
        #expect(third.version == "2.3")
        #expect(third.classes == third.dictCount + 1)
        #expect(third.blankIndex == third.dictCount)
        #expect(third.height == 32)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Resources/OCRModels/\(third.file)").path))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Resources/OCRModels/\(third.dictFile)").path))
    }

    @Test func traceRoundTripsThirdIdentityAndSchema() throws {
        let trace = OCRDebugTrace(
            model: "m", modelSHA256: "s", thirdModel: "third", thirdModelSHA256: "ts",
            engine: "e", totalLatencyMs: 3, lines: [
                .init(lineIndex: 0, bbox: [], visionText: "v", paddleText: "p",
                      rawPaddleText: "raw", cnocrText: "c", visionConfidence: 0,
                      paddleConfidence: 0, cropWidth: 0, cropHeight: 0,
                      recWidth: 0, timesteps: 0, latencyMs: 0),
            ])
        #expect(trace.schemaVersion == 3)
        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(OCRDebugTrace.self, from: data)
        #expect(decoded == trace)
        #expect(decoded.thirdModel == "third")
        #expect(decoded.lines[0].rawPaddleText == "raw")
        #expect(decoded.lines[0].cnocrText == "c")
    }
}
