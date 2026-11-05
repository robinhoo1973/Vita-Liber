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
/// 每次采集落**一个**文件 `<会话目录>/recognition-debug/<时间-模态-id6>.json`，内含
/// `input`（融合前各引擎原文与证据）与 `output`（只提示结果 + 门控改写 what-if）。
/// **只存文本**（业主 2026-11-04 第二批）：录音只在系统临时目录暂存供 Apple 重放，
/// 用完即删；原件/页图从不复制。**交付给用户的文本不变**。
@MainActor
enum RecognitionDebugRecorder {
    static var isEnabled: Bool { OCRShadowDiagnostics.isEnabled }

    /// Apple 第二、第三模型的固定语言（业主 2026-11-04）。
    static let appleReplayLocales = ["zh-CN", "en-US"]

    private static let stagingFolder = "recognition-debug-staging"
    private static var stagingPurged = false

    /// 进程内首次（冷启动首个 .active）清除暂存残留：采集中途被杀时 `defer` 删不到。
    /// 只做一次——之后回前台可能正有 Apple 重放在读暂存录音。
    static func purgeStagingAudio() {
        guard !stagingPurged else { return }
        stagingPurged = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(stagingFolder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.removeItem(at: directory)   // try?-ok: 暂存清理尽力而为
    }

    // MARK: - 语音

    struct ASRContext: Sendable {
        var result: TranscriptionResult
        var contextualStrings: [String]
        var languageMode: String
        var voiceLanguages: String
        var engineSetting: String
        var resolvedEngineID: String?
    }

    /// 同步复制录音到系统临时目录（仅供 Apple 中/英重放，`captureASR` 结束即删，
    /// 绝不进入调试目录）：聊天随后 `ChatAudioStore.adopt` 会移走原临时文件。
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
        let fileName = RecognitionDebugCapture.captureFileName(modality: .asr, date: now, captureID: captureID)

        var hypotheses = productionHypotheses(context)
        for locale in appleReplayLocales {
            // 生产编排已在采集后跑过 Apple 副源（2026-11-05）：同一 locale 的文本假设
            // 已在 result.hypotheses 里，不再文件重放一遍；否则同一引擎出现两份假设。
            if hypotheses.contains(where: {
                baseEngineID($0.engineID) == AppleSpeechFileTranscriber.engineID(locale: locale)
            }) {
                continue
            }
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
            deliveredText: context.result.text,
            segments: [RecognitionDebugCapture.Segment(index: 0, hypotheses: hypotheses)])
        // Apple 重放可能耗时数十秒：目录在重放**之后**再解析，期间会话被删除/切换时
        // 不会把已删除会话的转写重新写回 Files 树（闭包内仍复核代次）。
        let directoryName = await directory()
        await write(input: input, directoryName: directoryName, fileName: fileName, exportState: exportState)
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

    /// 一次聊天导入（单图或多页 PDF）= 一个采集文件；段序号 = 页序 × 1000 + 行序。
    static func captureOCR(documentID: UUID, traces: [OCRDebugTrace], exportState: DocumentExportState,
                           directory: @MainActor () async -> String) async {
        guard isEnabled, !traces.isEmpty else { return }
        let captureID = UUID()
        let now = Date()
        let fileName = RecognitionDebugCapture.captureFileName(modality: .ocr, date: now, captureID: captureID)
        let directoryName = await directory()
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
            deliveredText: delivered.joined(separator: "\n"), segments: segments)
        await write(input: input, directoryName: directoryName, fileName: fileName, exportState: exportState)
    }

    // MARK: - 落盘

    /// 后台融合后，把 input（融合前）+ output（融合后）合成一个 JSON 一次写出。
    private static func write(input: RecognitionDebugCapture.Input, directoryName: String, fileName: String,
                              exportState: DocumentExportState) async {
        let output = await Task.detached(priority: .utility) { () -> RecognitionDebugCapture.Output in
            let started = Date()
            var output = RecognitionDebugCapture.fuse(input, policy: HypothesisFusionMedicalPolicy.standard)
            output.elapsedMs = Date().timeIntervalSince(started) * 1000
            return output
        }.value
        let record = RecognitionDebugCapture.Record(input: input, output: output)
        guard let data = try? RecognitionDebugCapture.encode(record) else { return }   // try?-ok: 编码失败放弃本次采集
        await exportState.writeRecognitionDebug(directoryName: directoryName, fileName: fileName, data: data)
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
