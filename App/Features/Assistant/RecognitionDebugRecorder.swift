import Foundation
import UIKit
import Domain
import Infrastructure
import Protocols

/// 真机识别调试采集编排（2026-11-04 业主：真机给数据 → 回传分析）。
///
/// 开关 = 「帮助中心 → 系统诊断」同一开关（`OCRShadowDiagnostics`，默认关）。开启后：
/// - **语音**：主轨 = 生产按硬件/设置选出的引擎（照常交付）；同一段录音再交给
///   Apple 中文（zh-CN）、Apple 英文（en-US）各离线识别一遍作第二、第三模型；
/// - **图片**：主轨 = PP-OCRv6（内置），第二模型 = Apple Vision（同一行框逐行对照）。
///
/// 每次采集落一个目录 `<会话目录>/recognition-debug/<时间-模态-id6>/`：
/// 先写媒体（录音/原件）与 `input.json`（融合前各引擎原文与证据），再融合并写
/// `output.json`（只提示结果 + 门控改写 what-if）。**交付给用户的文本不变**。
@MainActor
enum RecognitionDebugRecorder {
    static var isEnabled: Bool { OCRShadowDiagnostics.isEnabled }

    /// Apple 第二、第三模型的固定语言（业主 2026-11-04）。
    static let appleReplayLocales = ["zh-CN", "en-US"]

    private static let stagingFolder = "recognition-debug-staging"

    // MARK: - 语音

    struct ASRContext: Sendable {
        var result: TranscriptionResult
        var contextualStrings: [String]
        var languageMode: String
        var voiceLanguages: String
        var engineSetting: String
        var resolvedEngineID: String?
    }

    /// 同步复制录音到临时暂存：聊天随后 `ChatAudioStore.adopt` 会移走原临时文件。
    static func stageAudio(_ url: URL?) -> URL? {
        guard isEnabled, let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(stagingFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "caf" : url.pathExtension
            let target = directory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    static func captureASR(_ context: ASRContext, stagedAudio: URL?, exportState: DocumentExportState,
                           directory: @MainActor () async -> String) async {
        defer { if let stagedAudio { try? FileManager.default.removeItem(at: stagedAudio) } }   // try?-ok: 暂存清理尽力而为
        guard isEnabled else { return }
        let captureID = UUID()
        let now = Date()
        let folder = RecognitionDebugCapture.captureFolderName(modality: .asr, date: now, captureID: captureID)
        let directoryName = await directory()

        var mediaFiles: [String] = []
        if let stagedAudio {
            let name = "audio." + (stagedAudio.pathExtension.isEmpty ? "caf" : stagedAudio.pathExtension)
            if await exportState.copyRecognitionDebug(directoryName: directoryName, captureFolder: folder,
                                                      fileName: name, from: stagedAudio) {
                mediaFiles.append(name)
            }
        }

        var hypotheses = productionHypotheses(context)
        for locale in appleReplayLocales {
            if let duplicate = duplicateReason(locale: locale, production: hypotheses) {
                hypotheses.append(.init(engineID: AppleSpeechFileTranscriber.engineID(locale: locale),
                                        sourceGroup: "apple-speech", role: .secondary, status: .skipped,
                                        reason: duplicate, locale: locale, text: ""))
                continue
            }
            guard let stagedAudio else {
                hypotheses.append(.init(engineID: AppleSpeechFileTranscriber.engineID(locale: locale),
                                        sourceGroup: "apple-speech", role: .secondary, status: .skipped,
                                        reason: "no-audio", locale: locale, text: ""))
                continue
            }
            hypotheses.append(await AppleSpeechFileTranscriber.transcribe(
                audioURL: stagedAudio, locale: locale, contextualStrings: context.contextualStrings))
        }

        let input = RecognitionDebugCapture.Input(
            captureID: captureID.uuidString, modality: .asr,
            createdAt: RecognitionDebugCapture.isoTimestamp(now),
            environment: environment(),
            request: [
                "voiceLanguages": context.voiceLanguages,
                "languageMode": context.languageMode,
                "engineSetting": context.engineSetting,
                "resolvedEngineID": context.resolvedEngineID ?? "",
                "resultEngineID": context.result.engineID ?? "",
                "resolvedLocale": context.result.resolvedLocale,
                "completion": String(describing: context.result.completion),
                "contextualStringCount": String(context.contextualStrings.count),
                "replayLocales": appleReplayLocales.joined(separator: ","),
            ],
            mediaFiles: mediaFiles, deliveredText: context.result.text,
            segments: [RecognitionDebugCapture.Segment(index: 0, hypotheses: hypotheses)])
        await write(input: input, directoryName: directoryName, folder: folder, exportState: exportState)
    }

    /// 生产主轨（及同一引擎内的辅轨，如双语基线轨的第二个 locale 实例）。
    private static func productionHypotheses(_ context: ASRContext) -> [RecognitionDebugCapture.Hypothesis] {
        let result = context.result
        var raw = result.hypotheses
        if raw.isEmpty {
            raw = [TranscriptionHypothesis(engineID: result.engineID ?? context.resolvedEngineID ?? "primary",
                                           localeIdentifier: result.resolvedLocale, text: result.text)]
        }
        // 同一引擎多 locale 实例（如 classic zh+en）engineID 相同——融合以 engineID 为键，必须区分。
        let counts = Dictionary(raw.map { ($0.engineID, 1) }, uniquingKeysWith: +)
        let primaryIndex = raw.firstIndex { $0.engineID == result.engineID } ?? 0
        return raw.enumerated().map { index, hypothesis in
            var hypothesis = hypothesis
            if counts[hypothesis.engineID, default: 0] > 1 {
                hypothesis.engineID += ":" + (hypothesis.localeIdentifier ?? String(index))
            }
            let isApple = !(VoiceEngineChoice(rawValue: baseEngineID(hypothesis.engineID))?.isBundledModel ?? false)
            return RecognitionDebugCapture.Hypothesis(
                hypothesis, sourceGroup: isApple ? "apple-speech-live" : "sherpa",
                role: index == primaryIndex ? .primary : .secondary)
        }
    }

    /// 生产本身就是 Apple 基线轨同语言时，文件重放是同源重复——记跳过，不当独立投票。
    private static func duplicateReason(locale: String,
                                        production: [RecognitionDebugCapture.Hypothesis]) -> String? {
        let language = locale.prefix(2).lowercased()
        let duplicate = production.contains { hypothesis in
            baseEngineID(hypothesis.engineID) == VoiceEngineChoice.classic.rawValue
                && (hypothesis.locale ?? "").prefix(2).lowercased() == language
        }
        return duplicate ? "duplicate-of-production-classic" : nil
    }

    private static func baseEngineID(_ engineID: String) -> String {
        String(engineID.split(separator: ":").first ?? Substring(engineID))
    }

    // MARK: - 图片

    /// 一次聊天导入（单图或多页 PDF）= 一个采集目录；段序号 = 页序 × 1000 + 行序。
    static func captureOCR(documentID: UUID, traces: [OCRDebugTrace], exportState: DocumentExportState,
                           directory: @MainActor () async -> String) async {
        guard isEnabled, !traces.isEmpty else { return }
        let captureID = UUID()
        let now = Date()
        let folder = RecognitionDebugCapture.captureFolderName(modality: .ocr, date: now, captureID: captureID)
        let directoryName = await directory()
        var mediaFiles: [String] = []
        if let original = await exportState.copyOriginalForRecognitionDebug(
            documentID: documentID, directoryName: directoryName, captureFolder: folder) {
            mediaFiles.append(original)
        }
        var segments: [RecognitionDebugCapture.Segment] = []
        var delivered: [String] = []
        var paddleNotes: [String] = []
        for trace in traces.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            for line in trace.lines where line.lineIndex < 0 {
                paddleNotes.append("page\(trace.pageIndex):\(trace.engine):\(line.error ?? "")")
            }
            for var segment in RecognitionDebugCapture.ocrSegments(from: trace) {
                segment.index = trace.pageIndex * 1000 + segment.index
                segments.append(segment)
                delivered.append(segment.hypotheses.first { $0.engineID == "apple-vision" }?.text ?? "")
            }
        }
        let input = RecognitionDebugCapture.Input(
            captureID: captureID.uuidString, modality: .ocr,
            createdAt: RecognitionDebugCapture.isoTimestamp(now),
            environment: environment(),
            request: [
                "documentID": documentID.uuidString,
                "pageCount": String(traces.count),
                "segmentIndex": "pageIndex*1000+lineIndex",
                "bbox": "Vision line box, normalized [x,y,w,h], top-left origin, relative to the processed page image",
                "primaryModel": traces.first.map { "\($0.model) sha256=\($0.modelSHA256)" } ?? "",
                "deliveredBy": "apple-vision (production still delivers Vision text; PP-OCRv6 is primary only in this capture until the owner rules on device data)",
                "paddleNotes": paddleNotes.joined(separator: ";"),
            ],
            mediaFiles: mediaFiles, deliveredText: delivered.joined(separator: "\n"), segments: segments)
        await write(input: input, directoryName: directoryName, folder: folder, exportState: exportState)
    }

    // MARK: - 落盘

    /// 先写 input.json（融合前），再后台融合，最后写 output.json（融合后）。
    private static func write(input: RecognitionDebugCapture.Input, directoryName: String, folder: String,
                              exportState: DocumentExportState) async {
        guard let inputData = try? RecognitionDebugCapture.encode(input) else { return }   // try?-ok: 编码失败放弃本次采集
        guard await exportState.writeRecognitionDebug(directoryName: directoryName, captureFolder: folder,
                                                      fileName: "input.json", data: inputData) else { return }
        let output = await Task.detached(priority: .utility) { () -> RecognitionDebugCapture.Output in
            let started = Date()
            var output = RecognitionDebugCapture.fuse(input)
            output.elapsedMs = Date().timeIntervalSince(started) * 1000
            return output
        }.value
        guard let outputData = try? RecognitionDebugCapture.encode(output) else { return }   // try?-ok: 编码失败只缺 output.json
        await exportState.writeRecognitionDebug(directoryName: directoryName, captureFolder: folder,
                                                fileName: "output.json", data: outputData)
    }

    private static func environment() -> [String: String] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let info = Bundle.main.infoDictionary
        return [
            "appVersion": (info?["CFBundleShortVersionString"] as? String) ?? "",
            "appBuild": (info?["CFBundleVersion"] as? String) ?? "",
            "systemName": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "deviceModel": machine,
            "physicalMemoryGB": String(format: "%.1f", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824),
            "uiLanguage": Locale.preferredLanguages.first ?? "",
        ]
    }
}
