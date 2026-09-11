#if canImport(SherpaOnnxC)
import Foundation
import Domain
import SherpaOnnxC

/// 钉版C API的有限适配层。与上游Swift包装器的fatalError初始化不同，空句柄抛可恢复错误。
/// 所有方法只由SherpaSpeechSessionDriver.inferenceQueue调用。
final class SherpaASRRuntime {
    private let choice: VoiceEngineChoice
    private var online: OpaquePointer?
    private var offline: OpaquePointer?
    private var stream: OpaquePointer?
    private var vad: OpaquePointer?
    private var committed: [String] = []
    private var recent: [Float] = []
    private var recentStart = 0
    private var samplesSeen = 0
    private var lastPreviewAt = 0
    private var preview = ""

    init(choice: VoiceEngineChoice, language: String, assets: ASRModelAssets.Validated, hotwords: [String] = []) throws {
        self.choice = choice
        let strings = CStringStorage()
        if choice == .zipformer {
            var config = SherpaOnnxOnlineRecognizerConfig()
            config.feat_config.sample_rate = 16_000
            config.feat_config.feature_dim = 80
            config.model_config.tokens = try strings.add(assets.path("tokens"))
            config.model_config.transducer.encoder = try strings.add(assets.path("encoder"))
            config.model_config.transducer.decoder = try strings.add(assets.path("decoder"))
            config.model_config.transducer.joiner = try strings.add(assets.path("joiner"))
            config.model_config.num_threads = 2
            config.model_config.provider = strings.add("cpu")
            config.model_config.model_type = strings.add("zipformer")
            config.model_config.modeling_unit = strings.add("cjkchar+bpe")
            config.model_config.bpe_vocab = try strings.add(assets.path("bpe"))
            config.decoding_method = strings.add("modified_beam_search")
            config.max_active_paths = 4
            config.hotwords_score = 1.5
            config.enable_endpoint = 1
            config.rule1_min_trailing_silence = 2.4
            config.rule2_min_trailing_silence = 0.8
            config.rule3_min_utterance_length = 20
            online = SherpaOnnxCreateOnlineRecognizer(&config)
            guard online != nil else { throw TranscriptionError.engineUnavailable }
        } else {
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = 16_000
            config.feat_config.feature_dim = 80
            config.model_config.tokens = choice == .qwen3 ? strings.add("") : try strings.add(assets.path("tokens"))
            config.model_config.num_threads = 2
            config.model_config.provider = strings.add("cpu")
            config.decoding_method = strings.add("greedy_search")
            config.max_active_paths = 4
            if choice == .dolphin {
                config.model_config.dolphin.model = try strings.add(assets.path("model"))
            } else if choice == .whisper {
                config.model_config.whisper.encoder = try strings.add(assets.path("encoder"))
                config.model_config.whisper.decoder = try strings.add(assets.path("decoder"))
                config.model_config.whisper.language = strings.add(language)
                config.model_config.whisper.task = strings.add("transcribe")
                config.model_config.whisper.tail_paddings = -1
            } else if choice == .qwen3 {
                config.model_config.qwen3_asr.conv_frontend = try strings.add(assets.path("frontend"))
                config.model_config.qwen3_asr.encoder = try strings.add(assets.path("encoder"))
                config.model_config.qwen3_asr.decoder = try strings.add(assets.path("decoder"))
                config.model_config.qwen3_asr.tokenizer = try strings.add(URL(fileURLWithPath: assets.path("vocab")).deletingLastPathComponent().path)
                config.model_config.qwen3_asr.max_total_len = 512
                config.model_config.qwen3_asr.max_new_tokens = 128
                config.model_config.qwen3_asr.temperature = 0.000001
                config.model_config.qwen3_asr.top_p = 0.8
                config.model_config.qwen3_asr.seed = 42
                config.model_config.qwen3_asr.hotwords = strings.add(ASRModelCatalog.qwenHotwords(hotwords))
            } else { throw TranscriptionError.engineUnavailable }
            offline = SherpaOnnxCreateOfflineRecognizer(&config)
            guard offline != nil else { throw TranscriptionError.engineUnavailable }
            var vadConfig = SherpaOnnxVadModelConfig()
            vadConfig.sample_rate = 16_000
            vadConfig.num_threads = 1
            vadConfig.provider = strings.add("cpu")
            vadConfig.silero_vad.model = try strings.add(assets.path("vad"))
            vadConfig.silero_vad.threshold = 0.5
            vadConfig.silero_vad.min_silence_duration = 0.6
            vadConfig.silero_vad.min_speech_duration = 0.25
            vadConfig.silero_vad.window_size = 512
            vadConfig.silero_vad.max_speech_duration = 8
            vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 30)
            guard vad != nil else {
                if let offline { SherpaOnnxDestroyOfflineRecognizer(offline) }
                self.offline = nil
                throw TranscriptionError.engineUnavailable
            }
        }
        // Keep all configuration strings alive until the native create call has copied them.
        withExtendedLifetime(strings) {}
    }

    deinit {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        if let online { SherpaOnnxDestroyOnlineRecognizer(online) }
        if let offline { SherpaOnnxDestroyOfflineRecognizer(offline) }
        if let vad { SherpaOnnxDestroyVoiceActivityDetector(vad) }
    }

    func begin(hotwords: [String]) throws {
        if let stream { SherpaOnnxDestroyOnlineStream(stream); self.stream = nil }
        if let online {
            // Raw text hotwords are tokenized by the model's cjkchar+bpe vocabulary; never write a hotword file.
            let words = hotwords.prefix(MixedSpeechVocabulary.limit).map {
                $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            }.joined(separator: "\n")
            stream = words.isEmpty ? SherpaOnnxCreateOnlineStream(online)
                : words.withCString { SherpaOnnxCreateOnlineStreamWithHotwords(online, $0) }
            guard stream != nil else { throw TranscriptionError.engineUnavailable }
        }
        if let vad { SherpaOnnxVoiceActivityDetectorReset(vad) }
        committed = []; recent = []; recentStart = 0; samplesSeen = 0; lastPreviewAt = 0; preview = ""
    }

    func accept(_ samples: [Float], final: Bool, cancelled: () -> Bool) throws -> String {
        guard !cancelled() else { throw CancellationError() }
        if let online, let stream {
            if !samples.isEmpty { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, samples, Int32(samples.count)) }
            if final {
                let padding = [Float](repeating: 0, count: 3_200)
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, padding, 3_200)
                SherpaOnnxOnlineStreamInputFinished(stream)
            }
            while SherpaOnnxIsOnlineStreamReady(online, stream) != 0 {
                guard !cancelled() else { throw CancellationError() }
                SherpaOnnxDecodeOnlineStream(online, stream)
            }
            guard let result = SherpaOnnxGetOnlineStreamResult(online, stream) else { throw TranscriptionError.engineUnavailable }
            let text = result.pointee.text.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            SherpaOnnxDestroyOnlineRecognizerResult(result)
            if !final, SherpaOnnxOnlineStreamIsEndpoint(online, stream) != 0 {
                if !text.isEmpty { committed.append(text) }
                SherpaOnnxOnlineStreamReset(online, stream)
                return committed.joined(separator: " ")
            }
            return (committed + (text.isEmpty ? [] : [text])).joined(separator: " ")
        }
        guard let vad else { throw TranscriptionError.engineUnavailable }
        guard recent.count + samples.count <= 30 * 16_000 else { throw TranscriptionError.audioBufferOverflow }
        recent.append(contentsOf: samples)
        samplesSeen += samples.count
        if !samples.isEmpty { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples, Int32(samples.count)) }
        if final { SherpaOnnxVoiceActivityDetectorFlush(vad) }
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard !cancelled() else { throw CancellationError() }
            guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad) else { throw TranscriptionError.engineUnavailable }
            let count = Int(segment.pointee.n), end = Int(segment.pointee.start) + Int(segment.pointee.n)
            guard count >= 0, count <= 30 * 16_000, let pointer = segment.pointee.samples else {
                SherpaOnnxDestroySpeechSegment(segment)
                throw TranscriptionError.engineUnavailable
            }
            let audio = Array(UnsafeBufferPointer(start: pointer, count: count))
            SherpaOnnxDestroySpeechSegment(segment)
            SherpaOnnxVoiceActivityDetectorPop(vad)
            let text = try decode(audio)
            if !text.isEmpty { committed.append(text) }
            let discard = max(0, min(recent.count, end - recentStart))
            recent.removeFirst(discard); recentStart += discard
            preview = ""; lastPreviewAt = samplesSeen
        }
        if !final, SherpaOnnxVoiceActivityDetectorDetected(vad) != 0 {
            let interval = choice == .dolphin ? 16_000 : 3 * 16_000
            if samplesSeen - lastPreviewAt >= interval, recent.count >= 8_000 {
                guard !cancelled() else { throw CancellationError() }
                preview = try decode(recent)
                lastPreviewAt = samplesSeen
            }
        } else if !final {
            // Long silence is not input for an autoregressive decoder (avoids silence hallucinations).
            let discard = max(0, recent.count - 8_000)
            recent.removeFirst(discard); recentStart += discard
        }
        guard !cancelled() else { throw CancellationError() }
        return (committed + (final || preview.isEmpty ? [] : [preview])).joined(separator: " ")
    }

    private func decode(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        guard let offline, let stream = SherpaOnnxCreateOfflineStream(offline) else { throw TranscriptionError.engineUnavailable }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxAcceptWaveformOffline(stream, 16_000, samples, Int32(samples.count))
        SherpaOnnxDecodeOfflineStream(offline, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw TranscriptionError.engineUnavailable }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return result.pointee.text.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }
}

private final class CStringStorage {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar>? {
        guard let pointer = strdup(value) else { return nil }
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { free($0) } }
}
#endif
