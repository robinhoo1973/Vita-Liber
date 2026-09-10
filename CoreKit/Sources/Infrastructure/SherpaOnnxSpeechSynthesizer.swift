import Foundation
import AVFoundation
import Domain
import Protocols
import sherpaOnnx

/// ADR-023 单轨制（V3.101）：Supertonic-3 ONNX 端侧离线语音合成。
///
/// 使用 sherpa-onnx 的 `SherpaOnnxOfflineTtsWrapper` 将文本转换为音频，
/// 再通过 `AVAudioPlayer` 播放。支持 31 语种（取决于 bundled voices.json）。
///
/// FR17.13 回读 / FR17.16 输出语言 / FR19.3 播报 均经此实现。
public final class SherpaOnnxSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let tts: SherpaOnnxOfflineTtsWrapper?
    private let availableVoiceIDs: [String]
    private var audioPlayer: AVAudioPlayer?
    private let lock = NSLock()

    public init?() {
        guard let config = Self.buildConfig() else {
            tts = nil
            availableVoiceIDs = []
            return
        }
        var cfg = config
        let t = SherpaOnnxOfflineTtsWrapper(config: &cfg)
        guard t != nil else {
            tts = nil
            availableVoiceIDs = []
            return
        }
        tts = t!
        availableVoiceIDs = Self.loadVoiceIDs()
    }

    // MARK: - SpeechSynthesizing

    @discardableResult
    public func speak(_ text: String, localeIdentifier: String) -> SpeechOutcome {
        guard let tts else {
            return SpeechOutcome(spokenLocale: localeIdentifier, didFallback: true)
        }

        let outcome = SpeechFallback.resolve(
            requested: localeIdentifier,
            availableVoices: Set(availableVoiceIDs)
        )

        // Find speaker ID for the resolved locale
        let sid = speakerID(for: outcome.spokenLocale)

        let audio = tts.generate(text: text, sid: sid, speed: 1.0)
        guard audio.n > 0, audio.sampleRate > 0 else {
            return outcome
        }

        // Convert float samples to Data (WAV format) for AVAudioPlayer
        guard let wavData = Self.createWavData(
            samples: audio.samples,
            sampleRate: Int(audio.sampleRate)
        ) else {
            return outcome
        }

        lock.lock()
        audioPlayer?.stop()
        do {
            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.play()
        } catch {
            audioPlayer = nil
        }
        lock.unlock()

        return outcome
    }

    public func stop() {
        lock.lock()
        audioPlayer?.stop()
        audioPlayer = nil
        lock.unlock()
    }

    // MARK: - Voice Helpers

    private func speakerID(for locale: String) -> Int {
        // voices.json maps locale → speaker ID; fallback to 0
        guard let index = availableVoiceIDs.firstIndex(of: locale) else { return 0 }
        return index
    }

    private static func loadVoiceIDs() -> [String] {
        guard let bundle = Bundle.main.path(forResource: "SherpaOnnxModels", ofType: nil) else {
            return []
        }
        let voicesPath = (bundle as NSString).appendingPathComponent("voices.json")
        guard let data = FileManager.default.contents(atPath: voicesPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return json.compactMap { $0["locale"] as? String }
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

        // PCM samples (float → int16)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16Sample.littleEndian) { Array($0) })
        }

        return data
    }

    // MARK: - Model Configuration

    private static func buildConfig() -> sherpaOnnxOfflineTtsConfig? {
        guard let bundle = Bundle.main.path(forResource: "SherpaOnnxModels", ofType: nil) else {
            return nil
        }

        let model = (bundle as NSString).appendingPathComponent("supertonic3.onnx")
        let tokens = (bundle as NSString).appendingPathComponent("supertonic3_tokens.txt")
        let voices = (bundle as NSString).appendingPathComponent("voices.json")

        guard FileManager.default.fileExists(atPath: model),
              FileManager.default.fileExists(atPath: tokens) else {
            return nil
        }

        let modelConfig = sherpaOnnxOfflineTtsModelConfig(
            vits: sherpaOnnxOfflineTtsVitsModelConfig(
                model: model,
                lexicon: "",
                tokens: tokens,
                dataDir: "",
                noiseScale: 0.667,
                noiseScaleW: 0.8,
                lengthScale: 1.0,
                dictDir: ""
            ),
            numThreads: 2,
            debug: 0,
            provider: "cpu"
        )

        var config = sherpaOnnxOfflineTtsConfig(
            model: modelConfig,
            ruleFsts: "",
            ruleFars: "",
            maxNumSentences: 1,
            silenceScale: 0.2
        )

        return config
    }
}
