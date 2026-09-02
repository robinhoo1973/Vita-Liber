import Foundation
import Domain
import Protocols
import Infrastructure

@main
enum OcrCli {
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            fputs("usage: OcrCli <image-path>\n", stderr)
            return
        }
        let path = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: path)
        // §7 纪律：不用 try?——读失败必须显式报告（L0 [1] 门禁）
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fputs("OcrCli: cannot read file: \(path) (\(error))\n", stderr)
            return
        }

        #if os(Linux)
        let engine: any ImageTextRecognizing = PaddleOCRImageRecognizer()
        let track = "PaddleOCR-on-ONNX (ADR-026 dev track)"
        #if canImport(COnnxRuntime)
        let ortVersion = await NativePPOCRRuntime.shared.ortVersion
        #else
        let ortVersion = "COnnxRuntime 未接入（占位）"
        #endif
        #else
        let engine: any ImageTextRecognizing = VisionImageRecognizer()
        let track = "Vision (Apple)"
        let ortVersion = "n/a (Apple 走 Vision)"
        #endif

        do {
            let rec = try await engine.recognize(data)
            for line in rec.lines { print(line) }
            print("---")
            print("track=\(track)")
            print("ortVersion=\(ortVersion)")
            print("lines=\(rec.lines.count) confidence=\(String(format: "%.3f", rec.confidence))")
            if rec.lines.isEmpty {
                print("note: 未识别到文本。Linux/dev 轨若 lines=0 且未接入 ONNX Runtime + PP-OCR 模型，")
                print("      说明 PaddleOCR 运行时未捆绑（占位退化），详见 tech-spec §5.2.2/§5.2.3。")
            }
        } catch {
            fputs("OcrCli: recognition failed: \(error)\n", stderr)
        }
    }
}
