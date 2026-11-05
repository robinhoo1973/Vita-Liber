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

    @Test func argmaxDecoderMatchesSoftmaxTextAndSkipsBlank() {
        // 2 帧 × 3 类，blank=2：帧 0 取类 1（甲），帧 1 重复类 1 后接 blank。
        let logits: [Float] = [0, 5, -1, 0, 4, -1]
        let output = CTCDecoder.decodeArgmax(logits: logits, timesteps: 2, classes: 3,
                                             vocabulary: ["乙", "甲", ""], blankIndex: 2)
        #expect(output.text == "甲")
        #expect(output.emittedCharacters == 1)
        #expect(output.confidence == 0)
        let invalid = CTCDecoder.decodeArgmax(logits: [0, 1], timesteps: 3, classes: 3,
                                              vocabulary: ["a", "b", ""], blankIndex: 2)
        #expect(invalid.text.isEmpty)
    }

    @Test func lineConsensusNeedsBothSecondariesAndKeepsNumbers() {
        let policy = HypothesisFusionPolicy.generic
        #expect(OCRLineConsensus.select(primary: "今天头通", vision: "今天头痛",
                                        cnocr: "今天头痛", policy: policy) == "今天头痛")
        #expect(OCRLineConsensus.select(primary: "今天头通", vision: nil,
                                        cnocr: "今天头痛", policy: policy) == nil)
        #expect(OCRLineConsensus.select(primary: "血压120", vision: "血压130",
                                        cnocr: "血压130", policy: policy) == nil)
    }

    @Test func cleanTextStripsCnOCRControlPlaceholders() {
        #expect(OCRLineConsensus.cleanText("阿莫西林<space>胶囊<unused10>") == "阿莫西林 胶囊")
        #expect(OCRLineConsensus.cleanText("<unused3>") == "")
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
        let modelURL = root.appendingPathComponent("Resources/OCRModels/\(third.file)")
        let dictURL = root.appendingPathComponent("Resources/OCRModels/\(third.dictFile)")
        #expect(FileManager.default.fileExists(atPath: modelURL.path))
        #expect(FileManager.default.fileExists(atPath: dictURL.path))
        // 随包资产必须与 catalog 的字节数/字典计数一致——这是 `loadThird` 的 fail-closed
        // 前置条件；只查「文件在」无法阻止资产与目录脱钩（运行时第三源静默消失）。
        // sha256 由运行时校验；Linux 测试环境无 CryptoKit，不在纯 Domain 测试重复。
        let modelData = try Data(contentsOf: modelURL)
        let dictData = try Data(contentsOf: dictURL)
        #expect(modelData.count == third.bytes)
        #expect(dictData.count == third.dictBytes)
        let entries = try JSONDecoder().decode([String].self, from: dictData)
        #expect(entries.count == third.dictCount)
    }

    @Test func legacyV2TraceDecodesWithoutThirdFields() throws {
        let json = """
        {"schemaVersion":2,"pageIndex":0,"model":"m","modelSHA256":"s","engine":"e","totalLatencyMs":1,
         "lines":[{"lineIndex":0,"bbox":[],"visionText":"v","paddleText":"p","visionConfidence":0,
                   "paddleConfidence":0,"cropWidth":0,"cropHeight":0,"recWidth":0,"timesteps":0,
                   "latencyMs":0}]}
        """
        let trace = try JSONDecoder().decode(OCRDebugTrace.self, from: Data(json.utf8))
        #expect(trace.schemaVersion == 2)
        #expect(trace.thirdModel == nil)
        #expect(trace.thirdModelSHA256 == nil)
        #expect(trace.lines[0].rawPaddleText == nil)
        #expect(trace.lines[0].cnocrText == nil)
        #expect(trace.lines[0].paddleText == "p")
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
