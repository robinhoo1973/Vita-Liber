#if os(macOS)
// linux-blind: macOS 专用 Speech 端侧识别运行器（SFSpeechRecognizer）——Linux 型检编译空单元；行为只在业主 Mac 手动运行时可见（GitHub macOS runner 无法授予语音识别权限，CI 上恒跳过）
import Foundation
import Speech
import Testing
@testable import Domain

// binds: SU-M15-ASREVAL — 杀手实验 macOS 运行器：同一录音逐句喂 Apple zh-CN / en-US 端侧识别器，出报告与止损判定（无清单自动跳过）
//
// ═══ 用途（round3 §8 P0-A）════════════════════════════════════════════════════════════
// 把同一份录音逐句喂给多个识别系统，计时、计 MER，输出各单模 MER、逐句 oracle（参考）、切段 vs 连续、
// 保护类伤害、BR-012 急救召回/误报、延迟 p50/p95、逐词置信度 AUROC（Apple 轨取最终结果的段置信度），
// 并给出止损判定（ASREvaluationVerdict 五条规则）。Apple-en 去留只认 token 级证据（含/不含 Apple-en 的两条
// 融合输出经 EXTRA_RUNS 并入、VITALIBER_ASR_EVAL_APPLE_EN_ABLATION 指名）；harm/fix > 0.2 或所有置信源
// AUROC < 0.85 → 不放行自动改写；急救阳性样本 < 60 时判定标注「只能发现回归、不能证明安全」。
// 指标与判定全部在 Domain（Linux 可测）；本文件只负责「读清单 → 跑 Apple 识别 → 写报告」。
//
// ═══ 用法（业主自己的 Mac）══════════════════════════════════════════════════════════════
//   cd repos/vita-liber
//   VITALIBER_ASR_EVAL_MANIFEST=$HOME/asr-eval/manifest.json \
//   VITALIBER_ASR_EVAL_OUT=$HOME/asr-eval/out \
//   swift test --package-path CoreKit --filter ASREvaluationHarnessTests
// 未设置 VITALIBER_ASR_EVAL_MANIFEST 时本测试自动跳过（CI 与日常 swift test 均不受影响）。
//
// 环境变量：
//   VITALIBER_ASR_EVAL_MANIFEST     必填：清单 JSON 路径（格式见下）
//   VITALIBER_ASR_EVAL_AUDIO_DIR    音频根目录；缺省 = 清单所在目录
//   VITALIBER_ASR_EVAL_OUT          报告目录；缺省 = 系统临时目录/vitaliber-asr-eval
//   VITALIBER_ASR_EVAL_LOCALES      逗号分隔，缺省 zh-CN,en-US（engineID = classic:<locale>）
//   VITALIBER_ASR_EVAL_CONTEXTUAL   mixed（缺省：注入生产混说词表 MixedSpeechVocabulary.terms）| none
//   VITALIBER_ASR_EVAL_DRUG_NAMES   逗号分隔，模拟药箱库存药名，随混说词表注入
//   VITALIBER_ASR_EVAL_TIMEOUT      单句超时秒数，缺省 60（超时记 failed，按空假设计分）
//   VITALIBER_ASR_EVAL_EXTRA_RUNS   外部系统结果 JSON（[ASREvaluation.SystemRun]），并入同一报告——
//                                   Qwen3/SenseVoice（sherpa）与 Apple-zh 同 VAD 切段轨经此接入（见下「扩展点」）
//   VITALIBER_ASR_EVAL_PRIMARY      主轨 engineID；缺省：有 qwen3 用 qwen3，否则 classic:zh-CN
//   VITALIBER_ASR_EVAL_APPLE_EN     Apple-en engineID；缺省 classic:en-US
//   VITALIBER_ASR_EVAL_APPLE_EN_ABLATION    「含 Apple-en 的融合 engineID,不含 Apple-en 的融合 engineID」（两条融合输出
//                                   须已经 EXTRA_RUNS 并入）。由此算 token 级边际增益 + 配对 bootstrap CI + harm/fix；
//                                   未提供时规则 1 只出「证据不足（advisory）」、不建议删除——逐句 oracle 会系统性低估
//                                   只在句内少数英文词上起作用的引擎
//   VITALIBER_ASR_EVAL_LANGUAGE_FROM_PRIMARY 1 = 上述融合的语种标签取自主轨（终裁要求；不设即视为未满足 → advisory）
//   VITALIBER_ASR_EVAL_SEGMENTED    切段系统 engineID（无缺省）；VITALIBER_ASR_EVAL_CONTINUOUS 缺省 classic:zh-CN
//   VITALIBER_ASR_EVAL_CANDIDATES   逗号分隔：候选/融合系统（规则 3 被检对象；未指定 = 安全回归未评估 → stop）
//   VITALIBER_ASR_EVAL_REQUEST_AUTH 1 = 授权未决时强制发起申请（宿主缺用途说明时系统可能直接终止进程）
//
// 授权：识别前先查 SFSpeechRecognizer.authorizationStatus()。未授权/受限/该 locale 不支持端侧识别时，该系统记
// skipped 并写理由——测试不红，报告里如实显示「已跳过」，止损判定按缺证据处理。`swift test` 的测试宿主没有
// NSSpeechRecognitionUsageDescription，此时**不会**发起授权申请（申请会被系统以隐私违规终止进程）；请在已获
// 「语音识别」授权的终端/宿主中运行，或自担风险设 VITALIBER_ASR_EVAL_REQUEST_AUTH=1。未在「系统设置 → 键盘 →
// 听写」下载对应语言的端侧模型时，supportsOnDeviceRecognition 为 false → 记 skipped。
//
// 清单格式（JSON；模板 = Fixtures/asr-eval/manifest.template.json，全部为合成示例）：
//   {
//     "schemaVersion": 1,
//     "utterances": [
//       { "utteranceID": "mixed-001", "audioPath": "mixed/mixed-001.wav",
//         "reference": "Yes，你说的很对", "tags": ["mixed"] },
//       { "utteranceID": "numeric-001", "audioPath": "numeric/numeric-001.m4a",
//         "reference": "阿莫西林每次500毫克", "tags": ["numeric", "drug"], "protectedTerms": ["阿莫西林"] }
//     ]
//   }
//   tags ∈ mixed / numeric / negation / drug / emergencyPositive / emergencyNegative（可省略）；
//   audioPath 相对音频根目录（禁绝对路径与 ..）；protectedTerms 可选、每项必须出现在 reference 中。
//   清单有任何问题 → 测试红并逐条列出（不跑出「绿」报告）；清单引用的音频缺失 → 写完报告后测试红。
//
// 产出（全部只在本机——含参考与假设原文，绝不入库）：
//   <OUT>/asr-eval-report.json  报告 + 止损判定（Codable，键排序；含逐句明细）
//   <OUT>/asr-eval-report.md    指标摘要表（不含原文），同时打印到测试输出
//   <OUT>/asr-eval-runs.json    各系统原始结果（[ASREvaluation.SystemRun]），可复算或与外部结果合并
//
// 扩展点（本期不实现）：sherpa 引擎（qwen3 / sense-voice / zipformer / fire-red）需 Infrastructure 的
// ASRModelAssets 定位已安装模型目录（ActivePointerStore.activeAssets）+ SherpaASRRuntime 离线解码，峰值内存取
// task_info phys_footprint；Apple-zh「同 VAD 切段」轨需 silero VAD 段界。两者落地前，可在 Mac 上用 sherpa-onnx
// 官方 CLI 离线解码同一批音频，按 SystemRun JSON 写出后经 VITALIBER_ASR_EVAL_EXTRA_RUNS 并入本报告。
// Apple 识别在系统进程内执行（WWDC25 #277），本进程 RSS 不代表其内存，故 Apple 轨 peakMemoryBytes 留空。

@Suite("SU-M15-ASREVAL · macOS 杀手实验运行器（SFSpeech 端侧 · 需清单）", .serialized)
struct ASREvaluationHarnessTests {

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func value(_ key: String) -> String? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static func list(_ key: String) -> [String] {
        (value(key) ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static var isConfigured: Bool { value("VITALIBER_ASR_EVAL_MANIFEST") != nil }

    static var locales: [String] {
        let configured = list("VITALIBER_ASR_EVAL_LOCALES")
        return configured.isEmpty ? ["zh-CN", "en-US"] : configured
    }

    static var timeoutSeconds: Double {
        value("VITALIBER_ASR_EVAL_TIMEOUT").flatMap { Double($0) }.map { max($0, 1) } ?? 60
    }

    @Test("同一录音喂多引擎 → 报告 + 止损判定",
          .enabled(if: isConfigured, "未设置 VITALIBER_ASR_EVAL_MANIFEST：无语料，跳过"),
          .timeLimit(.minutes(120)))
    func runKillerExperiment() async throws {
        let manifestPath = try #require(Self.value("VITALIBER_ASR_EVAL_MANIFEST"))
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try ASREvaluation.decodeManifest(from: manifestData)
        let audioDirectory = Self.value("VITALIBER_ASR_EVAL_AUDIO_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? manifestURL.deletingLastPathComponent()
        let missingAudio = manifest.utterances.compactMap { utterance -> String? in
            guard let audioPath = utterance.audioPath else { return nil }
            return FileManager.default.fileExists(
                atPath: audioDirectory.appendingPathComponent(audioPath).path) ? nil : utterance.utteranceID
        }

        var runs: [ASREvaluation.SystemRun] = []
        let authorizationProblem = await Self.speechAuthorizationProblem()
        for locale in Self.locales {
            if let authorizationProblem {
                runs.append(.skipped("classic:\(locale)", reason: authorizationProblem))
            } else {
                let run = await Self.runAppleRecognizer(locale: locale, manifest: manifest, audioDirectory: audioDirectory)
                runs.append(run)
            }
        }
        let externalRuns = try Self.extraRuns()
        runs.append(contentsOf: externalRuns)

        let report = ASREvaluation.evaluate(manifest: manifest, runs: runs)
        let verdict = ASREvaluationVerdict.evaluate(report: report, configuration: Self.verdictConfiguration(report))
        let outputDirectory = Self.value("VITALIBER_ASR_EVAL_OUT").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("vitaliber-asr-eval", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let reportJSON = try ASREvaluationRendering.json(report: report, verdict: verdict)
        try reportJSON.write(to: outputDirectory.appendingPathComponent("asr-eval-report.json"), options: .atomic)
        let markdown = ASREvaluationRendering.markdown(report: report, verdict: verdict)
        try Data(markdown.utf8).write(to: outputDirectory.appendingPathComponent("asr-eval-report.md"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(runs).write(to: outputDirectory.appendingPathComponent("asr-eval-runs.json"), options: .atomic)
        print(markdown)
        print("[asr-eval] 报告目录：\(outputDirectory.path)")
        #expect(missingAudio.isEmpty,
                "清单引用的音频缺失（相对 \(audioDirectory.path)）：\(missingAudio.joined(separator: ", "))")
    }

    // MARK: - 判定配置

    static func verdictConfiguration(_ report: ASREvaluation.Report) -> ASREvaluationVerdict.Configuration {
        let defaultPrimary = report.includedEngineIDs.contains("qwen3") ? "qwen3" : "classic:zh-CN"
        let primary = value("VITALIBER_ASR_EVAL_PRIMARY") ?? defaultPrimary
        let ablation = list("VITALIBER_ASR_EVAL_APPLE_EN_ABLATION")
        var tokenEvidence: ASREvaluationVerdict.TokenLevelEvidence?
        if ablation.count == 2 {
            tokenEvidence = ASREvaluationVerdict.TokenLevelEvidence.fusionAblation(
                report: report, primaryEngineID: primary, withEngineID: ablation[0], withoutEngineID: ablation[1],
                languageFromPrimary: value("VITALIBER_ASR_EVAL_LANGUAGE_FROM_PRIMARY") == "1")
        }
        return ASREvaluationVerdict.Configuration(
            primaryEngineID: primary,
            appleEnglishEngineID: value("VITALIBER_ASR_EVAL_APPLE_EN") ?? "classic:en-US",
            appleEnglishTokenLevelEvidence: tokenEvidence,
            segmentedEngineID: value("VITALIBER_ASR_EVAL_SEGMENTED"),
            continuousEngineID: value("VITALIBER_ASR_EVAL_CONTINUOUS") ?? "classic:zh-CN",
            candidateEngineIDs: list("VITALIBER_ASR_EVAL_CANDIDATES"))
    }

    static func extraRuns() throws -> [ASREvaluation.SystemRun] {
        guard let path = value("VITALIBER_ASR_EVAL_EXTRA_RUNS") else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([ASREvaluation.SystemRun].self, from: data)
    }

    // MARK: - Apple 端侧识别

    /// nil = 已授权；否则为整系统跳过的理由。
    static func speechAuthorizationProblem() async -> String? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return nil
        case .denied:
            return "语音识别授权被拒绝（系统设置 → 隐私与安全性 → 语音识别）"
        case .restricted:
            return "语音识别受设备策略限制"
        case .notDetermined:
            let hasUsageDescription = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
            guard hasUsageDescription || value("VITALIBER_ASR_EVAL_REQUEST_AUTH") == "1" else {
                return "测试宿主未获语音识别授权，且 Info.plist 缺 NSSpeechRecognitionUsageDescription——"
                    + "为免系统终止进程不发起申请（见文件头「授权」）"
            }
            let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            return status == .authorized ? nil : "语音识别授权申请未通过（status=\(status.rawValue)）"
        @unknown default:
            return "未知的语音识别授权状态"
        }
    }

    static func contextualStrings(for locale: String) -> [String] {
        guard value("VITALIBER_ASR_EVAL_CONTEXTUAL") != "none" else { return [] }
        return MixedSpeechVocabulary.terms(primaryLocale: locale, otherLocales: locales.filter { $0 != locale },
                                           recentDrugNames: list("VITALIBER_ASR_EVAL_DRUG_NAMES"))
    }

    /// 逐句串行识别（同一识别器同一时刻只跑一个任务；两个 Apple 识别器并发无官方保证——round3 A4）。
    static func runAppleRecognizer(locale: String, manifest: ASREvaluation.Manifest,
                                   audioDirectory: URL) async -> ASREvaluation.SystemRun {
        let engineID = "classic:\(locale)"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            return .skipped(engineID, reason: "SFSpeechRecognizer 不支持 locale \(locale)")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .skipped(engineID, reason: "\(locale) 不支持端侧识别（requiresOnDeviceRecognition 无法满足；"
                            + "可在系统设置 → 键盘 → 听写下载该语言）")
        }
        guard recognizer.isAvailable else {
            return .skipped(engineID, reason: "\(locale) 识别器当前不可用")
        }
        // 回调放到专用串行队列：Swift Testing 不保证主线程 run loop 在转，默认主队列回调可能永不送达。
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        recognizer.queue = callbacks
        let contextual = contextualStrings(for: locale)
        let timeout = timeoutSeconds
        let clock = ContinuousClock()
        var results: [ASREvaluation.UtteranceResult] = []
        for utterance in manifest.utterances {
            if Task.isCancelled { break }
            // 纯文本语料（无 audioPath）没有可重放的音频：该引擎如实跳过这一句。
            guard let audioPath = utterance.audioPath else {
                results.append(.skipped(utterance.utteranceID, reason: "纯文本语料（无 audioPath）"))
                continue
            }
            let url = audioDirectory.appendingPathComponent(audioPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                results.append(.skipped(utterance.utteranceID, reason: "音频文件缺失"))
                continue
            }
            let started = clock.now
            do {
                let output = try await recognize(url: url, recognizer: recognizer, contextualStrings: contextual,
                                                 timeoutSeconds: timeout)
                results.append(.recognized(utterance.utteranceID, hypothesis: output.text,
                                           latencyMilliseconds: milliseconds(started.duration(to: clock.now)),
                                           tokens: output.tokens.isEmpty ? nil : output.tokens))
            } catch {
                results.append(.failed(utterance.utteranceID, reason: describe(error),
                                       latencyMilliseconds: milliseconds(started.duration(to: clock.now))))
            }
            if let last = results.last {
                let latency = last.latencyMilliseconds.map { "\(Int($0)) ms" } ?? "—"
                print("[asr-eval] \(engineID) \(utterance.utteranceID) \(last.status.rawValue) \(latency)")
            }
        }
        return ASREvaluation.SystemRun(
            engineID: engineID, results: results,
            notes: "SFSpeechURLRecognitionRequest; requiresOnDeviceRecognition=true; taskHint=dictation; "
                + "contextualStrings=\(contextual.count)")
    }

    /// 单句识别：续体等待最终结果，Speech 回调 / 超时 / 任务取消三方竞争，只放行第一个结果。
    /// 最终结果的段（`SFTranscriptionSegment`）按契约 `TranscriptionToken` 携带原生置信度/时间/替代写法，供 AUROC。
    private static func recognize(url: URL, recognizer: SFSpeechRecognizer, contextualStrings: [String],
                                  timeoutSeconds: Double) async throws -> RecognitionOutput {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        let gate = RecognitionGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RecognitionOutput, Error>) in
                gate.install(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let best = result.bestTranscription
                        let tokens = best.segments.map { segment -> TranscriptionToken in
                            TranscriptionToken(text: segment.substring, start: segment.timestamp,
                                               duration: segment.duration, confidence: Double(segment.confidence),
                                               alternatives: segment.alternativeSubstrings)
                        }
                        gate.finish(.success(RecognitionOutput(text: best.formattedString, tokens: tokens)))
                    } else if let error {
                        gate.finish(.failure(error))
                    }
                }
                gate.attach(task)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    gate.finish(.failure(HarnessError.timeout(seconds: timeoutSeconds)))
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    static func describe(_ error: Error) -> String {
        if let harness = error as? HarnessError { return harness.description }
        if error is CancellationError { return "已取消（超出测试时限或被中止）" }
        let native = error as NSError
        return "\(native.domain)#\(native.code)：\(native.localizedDescription)"
    }
}

/// 一句识别的产出：1-best 全文 + 逐段原生证据。
private struct RecognitionOutput: Sendable {
    let text: String
    let tokens: [TranscriptionToken]
}

private enum HarnessError: Error, CustomStringConvertible {
    case timeout(seconds: Double)

    var description: String {
        switch self {
        case .timeout(let seconds): return "识别超时（\(Int(seconds)) 秒）"
        }
    }
}

/// 一次性续体闸：先到的结果放行，其余丢弃；失败/超时/取消时顺带取消识别任务。锁保护全部状态。
private final class RecognitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RecognitionOutput, Error>?
    private var task: SFSpeechRecognitionTask?
    private var outcome: Result<RecognitionOutput, Error>?

    func install(_ continuation: CheckedContinuation<RecognitionOutput, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        let alreadyFinished = outcome != nil
        if !alreadyFinished { self.task = task }
        lock.unlock()
        if alreadyFinished { task.cancel() }
    }

    func finish(_ result: Result<RecognitionOutput, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = continuation
        let running = task
        continuation = nil
        task = nil
        lock.unlock()
        if case .failure = result { running?.cancel() }
        waiting?.resume(with: result)
    }
}
#endif
