import Foundation
import Domain
import Protocols
#if os(iOS)
import AVFoundation
import SherpaOnnx

/// Supertonic-3 ONNX 端侧离线语音合成（sherpa-onnx）。
///
/// **注意（V3.102 审查修正）**：Supertonic-3 经核实的 31 语种**不含中文**——
/// 本引擎无法承担 FR17.16 普通话回退链与 FR17.13 中文回读，生产装配
/// 由 `SpeechSynthesisFactory` 采用 `AVSpeechAdapter`（系统语音、零资产、
/// 含 zh-Hans/zh-Hant/en，ADR-025 平台框架优先）。本类保留为
/// **P1 多语种扩展候选**（非中文播报场景），未接入生产链路。
///
/// 正确配置契约（对照 sherpa-onnx `tts-supertonic-en` 官方示例）：
/// Supertonic 模型走 `supertonic:` 专用槽位——四件套 ONNX
/// （duration_predictor / text_encoder / vector_estimator / vocoder）
/// + `tts.json` + `unicode_indexer.bin` + `voice.bin`；**不是** vits 单文件。
public final class SherpaOnnxSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let tts: SherpaOnnxOfflineTtsWrapper
    /// voices.json 为可选 sidecar（Supertonic 官方包不含该文件）：
    /// 每条 `{locale, sid}`；缺失时可用语音集为空，回退链如实报告。
    private let voiceMap: [String: Int]
    private var audioPlayer: AVAudioPlayer?
    private let lock = NSLock()
    /// 合成串行队列：sherpa-onnx 对象无线程安全保证，且合成是 CPU 密集——
    /// 全部 generate 串行执行、播放前合成在后台完成（不得阻塞调用方主线程）
    private let synthQueue = DispatchQueue(label: "com.vitaliber.tts.sherpa")

    public init?() {
        guard let config = Self.buildConfig() else { return nil }
        var cfg = config
        // 包装器 init 不可失败、创建失败时持空指针——buildConfig 已预检
        // 四件套文件存在且非零体积（FR17.17 资产供应契约同 ASR 侧纪律）
        tts = SherpaOnnxOfflineTtsWrapper(config: &cfg)
        voiceMap = Self.loadVoiceMap()
    }

    // MARK: - SpeechSynthesizing

    @discardableResult
    public func speak(_ text: String, localeIdentifier: String) -> SpeechOutcome {
        // 回退链同步解析（SpeechFallback 单一规则源）；合成与播放后台执行
        let outcome = SpeechFallback.resolve(
            requested: localeIdentifier,
            availableVoices: Set(voiceMap.keys)
        )
        let sid = voiceMap[outcome.spokenLocale] ?? 0
        let tts = tts
        synthQueue.async { [weak self] in
            guard let self else { return }
            let audio = tts.generate(text: text, sid: sid, speed: 1.0)
            guard audio.n > 0, audio.sampleRate > 0,
                  let wavData = Self.createWavData(
                      samples: audio.samples,
                      sampleRate: Int(audio.sampleRate)
                  ) else {
                return
            }
            self.lock.lock()
            self.audioPlayer?.stop()
            do {
                self.audioPlayer = try AVAudioPlayer(data: wavData)
                self.audioPlayer?.play()
            } catch {
                self.audioPlayer = nil
            }
            self.lock.unlock()
        }
        return outcome
    }

    public func stop() {
        lock.lock()
        audioPlayer?.stop()
        audioPlayer = nil
        lock.unlock()
    }

    // MARK: - Voice Helpers

    /// voices.json sidecar：locale → 真实 sid（不复用数组下标——下标==sid
    /// 只在文件按 sid 有序时偶然成立，重排即错声）
    private static func loadVoiceMap() -> [String: Int] {
        guard let bundle = Bundle.main.path(forResource: "SherpaOnnxModels", ofType: nil) else {
            return [:]
        }
        let voicesPath = (bundle as NSString).appendingPathComponent("supertonic-voices.json")
        guard let data = FileManager.default.contents(atPath: voicesPath) else { return [:] }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { return [:] }
        guard let entries = json as? [[String: Any]] else { return [:] }
        var map: [String: Int] = [:]
        for entry in entries {
            guard let locale = entry["locale"] as? String, let sid = entry["sid"] as? Int else { continue }
            map[locale] = sid
        }
        return map
    }

    // MARK: - WAV Encoding

    private static func createWavData(samples: [Float], sampleRate: Int) -> Data? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate) * Int32(numChannels) * Int32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = Int32(samples.count * MemoryLayout<Int16>.size)
        let fileSize = 36 + dataSize

        // 单次分配 Int16 数组（原实现每样本分配两个临时 Array：10s 音频 ≈22 万次堆分配）
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            pcm.append(Int16(clamped * 32767.0))
        }

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) }) // chunk size
        data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) })  // PCM format
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }

        return data
    }

    // MARK: - Model Configuration

    private static func buildConfig() -> SherpaOnnxOfflineTtsConfig? {
        guard let bundle = Bundle.main.path(forResource: "SherpaOnnxModels", ofType: nil) else {
            return nil
        }
        let dir = (bundle as NSString).appendingPathComponent("supertonic-3")
        let required = [
            "duration_predictor.onnx", "text_encoder.onnx", "vector_estimator.onnx",
            "vocoder.onnx", "tts.json", "unicode_indexer.bin", "voice.bin",
        ].map { (dir as NSString).appendingPathComponent($0) }

        // 资产预检（FR17.17 资产供应契约）：缺件/空文件一律回落，不进 fatalError/空指针路径
        for path in required {
            let attrs: [FileAttributeKey: Any]
            do { attrs = try FileManager.default.attributesOfItem(atPath: path) }
            catch { return nil }
            if (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 0 { return nil }
        }

        let supertonic = sherpaOnnxOfflineTtsSupertonicModelConfig(
            durationPredictor: required[0],
            textEncoder: required[1],
            vectorEstimator: required[2],
            vocoder: required[3],
            ttsJson: required[4],
            unicodeIndexer: required[5],
            voiceStyle: required[6]
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(
            supertonic: supertonic,
            numThreads: 2,
            debug: 0,
            provider: "cpu"
        )
        // maxNumSentences: -1 = 全部句子单批处理（长文回读不分批截断）
        return sherpaOnnxOfflineTtsConfig(
            model: modelConfig,
            ruleFsts: "",
            ruleFars: "",
            maxNumSentences: -1,
            silenceScale: 0.2
        )
    }
}
#else
/// 非 iOS 编译占位（macOS/Linux 测试宿主）：sherpa-onnx 二进制仅在 iOS
/// 链接；生产 TTS = AVSpeechAdapter（系统语音，零资产），本类为
/// P1 非中文多语种扩展候选、未接生产链。
public final class SherpaOnnxSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public init?() { return nil }
    @discardableResult
    public func speak(_ text: String, localeIdentifier: String) -> SpeechOutcome {
        SpeechOutcome(spokenLocale: localeIdentifier, didFallback: false)
    }
    public func stop() {}
}
#endif
