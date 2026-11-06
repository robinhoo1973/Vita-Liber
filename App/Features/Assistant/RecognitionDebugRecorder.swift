import Foundation
import UIKit
import Domain
import Infrastructure
import Protocols

/// 真机识别调试采集编排（2026-11-04 业主：真机给数据 → 回传分析）。
///
/// 开关 = SP-48 关于页同一开关（`OCRShadowDiagnostics`，默认关；2026-11-05
/// 自帮助中心移入）。开启后：
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
            var replay = await AppleSpeechFileTranscriber.transcribe(
                audioURL: stagedAudio, locale: locale, contextualStrings: context.contextualStrings)
            replay.modelVersion = "apple-\(locale) source=system"
            hypotheses.append(replay)
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
                // 模型身份（2026-11-05 审查补充）：只写 engineID 时无法区分「同档位不同
                // 模型版本」——调参数据回传后无法复盘是随包版本还是下载版本。
                "primaryModelVersion": modelIdentity(context.result.engineID ?? context.resolvedEngineID),
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
        var identities: [String: String] = [:]
        return raw.enumerated().map { index, hypothesis in
            var hypothesis = hypothesis
            if counts[hypothesis.engineID, default: 0] > 1 {
                hypothesis.engineID += ":" + (hypothesis.localeIdentifier ?? String(index))
            }
            let isApple = !(VoiceEngineChoice(rawValue: baseEngineID(hypothesis.engineID))?.isBundledModel ?? false)
            let version = identities[hypothesis.engineID]
                ?? modelIdentity(hypothesis.engineID)
            identities[hypothesis.engineID] = version
            return RecognitionDebugCapture.Hypothesis(
                hypothesis, sourceGroup: isApple ? "apple-speech-live" : "sherpa",
                role: index == primaryIndex ? .primary : .secondary,
                modelVersion: version)
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

    /// 主轨模型身份字符串（调试 JSON）：随包/下载档给出目录版本与实际生效来源；
    /// 平台档（classic/advanced/dictation）由系统提供，版本随 `systemVersion` 即可。
    private static func modelIdentity(_ engineID: String?) -> String {
        guard let engineID, !engineID.isEmpty else { return "" }
        let base = baseEngineID(engineID)
        guard let choice = VoiceEngineChoice(rawValue: base), choice.isBundledModel else {
            return "\(base) source=system"
        }
        let installed = ASRModelDownloadService.installedVersion(for: choice)
        let catalog = ASRModelCatalog.model(for: choice,
                                            in: ASRFamilyIndexStore.routingIndex())?.version
        switch (installed, catalog) {
        case let (installed?, catalog?):
            return "\(base) version=\(installed) source=download catalog=\(catalog)"
        case let (installed?, nil):
            return "\(base) version=\(installed) source=download"
        case let (nil, catalog?):
            return "\(base) version=\(catalog) source=bundled"
        case (nil, nil):
            return "\(base) version=unknown source=bundled"
        }
    }

    // MARK: - 图片

    /// 一次聊天导入（单图或多页 PDF）= 一个采集文件；段序号 = 页序 × 1000 + 行序。
    ///
    /// `deliveredPages` = 各页**实际交付行**（`PageAnalysis.lines`，页号 → 行数组）。
    /// 交付文本必须由调用方传入：Paddle 主轨后 `apple-vision` 假设已不是交付基线，
    /// 旧实现拿它拼 `deliveredText`，调试 JSON 会把副轨原文记成交付文本。
    static func captureOCR(documentID: UUID, traces: [OCRDebugTrace], deliveredPages: [Int: [String]],
                           exportState: DocumentExportState,
                           directory: @MainActor () async -> String) async {
        guard isEnabled, !traces.isEmpty else { return }
        let captureID = UUID()
        let now = Date()
        let fileName = RecognitionDebugCapture.captureFileName(modality: .ocr, date: now, captureID: captureID)
        let directoryName = await directory()
        var segments: [RecognitionDebugCapture.Segment] = []
        var delivered: [String] = []
        var paddleNotes: [String] = []
        let orderedTraces = traces.sorted { $0.pageIndex < $1.pageIndex }
        for trace in orderedTraces {
            for line in trace.lines where line.lineIndex < 0 {
                paddleNotes.append("page\(trace.pageIndex):\(trace.engine):\(line.error ?? "")")
            }
            let pageLines = deliveredPages[trace.pageIndex] ?? []
            for var segment in RecognitionDebugCapture.ocrSegments(from: trace) {
                let lineIndex = segment.index
                segment.index = trace.pageIndex * 1000 + lineIndex
                segments.append(segment)
                if lineIndex >= 0, lineIndex < pageLines.count {
                    delivered.append(pageLines[lineIndex])
                } else {
                    // 交付行缺失（不应发生）：退回首个非空假设原文（Paddle 兜底行
                    // 的主轨文本为空，实际交付是 Vision 副轨），保持与 segments 对齐。
                    delivered.append(segment.hypotheses.first { !$0.text.isEmpty }?.text ?? "")
                }
            }
        }
        let pageModels = orderedTraces.map { trace -> String in
            var identity = "\(trace.model) sha256=\(trace.modelSHA256)"
            if let det = trace.detModel {
                identity += " det=\(det) sha256=\(trace.detModelSHA256 ?? "")"
            }
            if let third = trace.thirdModel {
                identity += " third=\(third) sha256=\(trace.thirdModelSHA256 ?? "")"
            }
            return "page\(trace.pageIndex):\(trace.engine):\(identity)"
        }.joined(separator: ";")
        // 第三源参与与否以**逐行证据**为准：thirdModel 只证明 12.5 MB 会话加载成功，
        // 逐行预处理/推理全失败时没有任何 cnocrText，实际没有第三票。同理，Paddle
        // 完全不可用的采集（annotated 轨迹无 det 身份）交付的是 Vision，不能声称
        // paddle-ppocrv6-rec 交付。元数据必须与真实运行面一致，否则无法复盘。
        let thirdVote = orderedTraces.contains { trace in
            trace.lines.contains { !($0.cnocrText ?? "").isEmpty }
        }
        let paddleDelivered = orderedTraces.contains { $0.detModel != nil }
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
                "pageModels": pageModels,
                // Paddle 主轨 + Vision/CnOCR 双副源共识：仅两副源同键且非受保护类时替换。
                "deliveredBy": !paddleDelivered
                    ? "Vision fallback (Paddle unavailable or produced no lines); lines come from Vision"
                    : thirdVote
                        ? "paddle-ppocrv6-rec; Vision layout/fallback; CnOCR third vote (Vision+CnOCR must agree)"
                        : "paddle-ppocrv6-rec (Vision supplies layout; lines without Paddle text keep Vision)",
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
