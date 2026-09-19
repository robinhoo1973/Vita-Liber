#if canImport(SherpaOnnxC)
import Foundation
import Domain
import SherpaOnnxC

/// 钉版C API的有限适配层。与上游Swift包装器的fatalError初始化不同，空句柄抛可恢复错误。
/// 所有方法只由SherpaSpeechSessionDriver.inferenceQueue调用。
final class SherpaASRRuntime {
    private let choice: VoiceEngineChoice
    /// 解码语言提示（`ASRModelDescriptor.decoderLanguage(for:mode:)`）：qwen3 只认官方名称
    /// （Chinese/Cantonese/English…），空串 = 不注入、启用模型自带语种识别（混说模式）；
    /// 此前传 ISO 码等于强制一个训练分布外的标签（round2 A-N1 根因）。qwen3 经 per-stream
    /// "language" 选项按会话注入（`begin(language:hotwords:)`），运行时可跨语言/模式复用；
    /// whisper 的语言在构造期写入 config，不在此字段。
    private var sessionLanguage = ""
    /// qwen3 per-stream 热词 CSV（`ASRModelCatalog.qwenHotwords`）；热词不再进 config/池键——
    /// 药箱变动不再触发整模重载（round2 A-N7）。
    private var sessionHotwords = ""
    /// 上次预览解码耗时（秒）：预览间隔按其自适应，避免预览挤占最终解码（round2 A-N3）。
    private var lastPreviewSeconds: Double = 0
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

    /// `language` 仅 whisper 消费（config.language 走 ISO 码）；qwen3/dolphin/zipformer 忽略。
    init(choice: VoiceEngineChoice, language: String, assets: ASRModelAssets.Validated) throws {
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
                // 热词改 per-stream SetOption("hotwords")（decode 内）：config 级热词会把运行时
                // 绑死在一份词表上，且占用 max_total_len 提示预算（round2 A-N4/A-N7）。
                config.model_config.qwen3_asr.hotwords = strings.add("")
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

    /// 每段（Job）开始调用：按会话装配解码语言提示与热词，复位窗口状态。
    func begin(language: String, hotwords: [String]) throws {
        if let stream { SherpaOnnxDestroyOnlineStream(stream); self.stream = nil }
        if let online {
            // Raw text hotwords are tokenized by the model's cjkchar+bpe vocabulary; never write a hotword file.
            // zipformer 上游把 "/" 当作热词分隔符（online-recognizer-transducer-impl.h），
            // "mmol/L" 会被拆散——先替换为空格（round2 A-N7）。
            let words = hotwords.prefix(MixedSpeechVocabulary.limit).map {
                $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "/", with: " ")
            }.joined(separator: "\n")
            stream = words.isEmpty ? SherpaOnnxCreateOnlineStream(online)
                : words.withCString { SherpaOnnxCreateOnlineStreamWithHotwords(online, $0) }
            guard stream != nil else { throw TranscriptionError.engineUnavailable }
        }
        sessionLanguage = choice == .qwen3 ? language : ""
        sessionHotwords = choice == .qwen3 ? ASRModelCatalog.qwenHotwords(hotwords) : ""
        if let vad { SherpaOnnxVoiceActivityDetectorReset(vad) }
        committed = []; recent = []; recentStart = 0; samplesSeen = 0; lastPreviewAt = 0; preview = ""
        lastPreviewSeconds = 0
    }

    /// `allowPreview` 为假时跳过本轮预览解码（调用方在 final 待处理/积压过大时让位，round2 A-N3）。
    func accept(_ samples: [Float], final: Bool, cancelled: () -> Bool,
                allowPreview: () -> Bool = { true }) throws -> String {
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
                return TranscriptJoiner.join(committed)
            }
            return TranscriptJoiner.join(committed + (text.isEmpty ? [] : [text]))
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
            // 预览让位（round2 A-N3）：预览与最终解码共用同一串行队列，间隔按上次预览耗时
            // 自适应（至少留出等长空闲），且调用方有 final/积压待处理时整轮跳过。
            let base = choice == .dolphin ? 16_000 : 3 * 16_000
            let interval = max(base, Int(lastPreviewSeconds * 2 * 16_000))
            if samplesSeen - lastPreviewAt >= interval, recent.count >= 8_000, allowPreview() {
                guard !cancelled() else { throw CancellationError() }
                let started = DispatchTime.now().uptimeNanoseconds
                preview = try decode(recent)
                lastPreviewSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
                lastPreviewAt = samplesSeen
            }
        } else if !final {
            // Long silence is not input for an autoregressive decoder (avoids silence hallucinations).
            let discard = max(0, recent.count - 8_000)
            recent.removeFirst(discard); recentStart += discard
        }
        guard !cancelled() else { throw CancellationError() }
        return TranscriptJoiner.join(committed + (final || preview.isEmpty ? [] : [preview]))
    }

    private func decode(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        guard let offline, let stream = SherpaOnnxCreateOfflineStream(offline) else { throw TranscriptionError.engineUnavailable }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        // qwen3 识别器按 per-stream 选项注入：`language` 原样编码为 "language <Name>" 提示
        // （vendored offline-recognizer-qwen3-asr-impl.cc），故只能传官方名称、空则交给模型自带
        // 语种识别；`hotwords` 为 ASCII 逗号 CSV。dolphin/whisper 不经此选项（whisper 已入 config）。
        if choice == .qwen3 {
            if !sessionLanguage.isEmpty { setOption(stream, "language", sessionLanguage) }
            if !sessionHotwords.isEmpty { setOption(stream, "hotwords", sessionHotwords) }
        }
        SherpaOnnxAcceptWaveformOffline(stream, 16_000, samples, Int32(samples.count))
        SherpaOnnxDecodeOfflineStream(offline, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw TranscriptionError.engineUnavailable }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return result.pointee.text.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    private func setOption(_ stream: OpaquePointer, _ key: String, _ value: String) {
        key.withCString { k in value.withCString { v in SherpaOnnxOfflineStreamSetOption(stream, k, v) } }
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
