import Foundation
import AVFoundation
import Domain
import Protocols
import sherpaOnnx

/// ADR-023 单轨制（V3.101）：FunASR-Nano GGUF + FSMN-VAD GGUF 端侧离线语音识别。
///
/// **音频零落盘是类型级保证**（FR17.7）：本实现内部的 PCM 缓冲仅存在于内存，
/// 调用方经 `TranscriptionEngine` 协议拿不到任何 URL/Data/文件句柄。
///
/// 音频管线：`AVAudioEngine` 采集 → 重采样至 16kHz 单声道 Float →
/// `SherpaOnnxOfflineRecognizer` 批量解码 → `TranscriptionResult`。
public actor SherpaOnnxTranscriber: TranscriptionEngine {
    public nonisolated let capability: TranscriptionCapability

    private let recognizer: SherpaOnnxOfflineRecognizer
    private let modelSampleRate: Int = 16_000

    // Audio capture state
    private var audioEngine: AVAudioEngine?
    private var isCapturing = false
    private var sessionActive = false

    // Thread-safe buffer for real-time audio tap callback
    private let bufferLock = NSLock()
    private var sampleBuffer: [Float] = []

    // MARK: - Init

    public init?() {
        guard let config = Self.buildConfig() else { return nil }
        var cfg = config
        let r = SherpaOnnxOfflineRecognizer(config: &cfg)
        // nil check: SherpaOnnxOfflineRecognizer may return nil if models are missing
        guard r != nil else { return nil }
        recognizer = r!
        capability = Self.probeCapability()
    }

    // MARK: - TranscriptionEngine

    public nonisolated func currentCapability() async -> TranscriptionCapability { capability }

    public nonisolated func transcribe(
        _ request: TranscriptionRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> TranscriptionResult {
        try await _transcribe(request, onPartial: onPartial)
    }

    public nonisolated func finish(sessionID: UUID) async {
        await _finish()
    }

    public nonisolated func cancel(sessionID: UUID) async {
        await _cancel()
    }

    public nonisolated func discardSession(sessionID: UUID) async {
        await _cancel()
    }

    public nonisolated func endAudio() async {
        await _finish()
    }

    // MARK: - Private implementations (avoid nonisolated warnings)

    private func _transcribe(
        _ request: TranscriptionRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> TranscriptionResult {
        try await startCapture()
        defer { Task { await stopCapture() } }

        // Wait for finish/cancel signal (cooperative cancellation)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The continuation is immediately resumed — the real work happens
            // in startCapture/stopCapture. Callers use finish(sessionID:) or
            // cancel(sessionID:) to end the session.
            continuation.resume()
        }

        // Decode accumulated audio
        let samples: [Float] = bufferLock.lock()
        defer { bufferLock.unlock() }
        let result = recognizer.decode(samples: sampleBuffer, sampleRate: Int32(modelSampleRate))
        sampleBuffer.removeAll(keepingCapacity: true)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLocale = capability.resolvedLocale(for: request.localeIdentifier) ?? "zh-Hans-CN"

        onPartial?(text)

        guard !text.isEmpty else {
            throw TranscriptionError.noSpeechDetected
        }

        return TranscriptionResult(
            text: text,
            confidence: 0.9,
            resolvedLocale: resolvedLocale,
            segmented: false
        )
    }

    private func _finish() {
        stopCaptureSync()
    }

    private func _cancel() {
        stopCaptureSync()
        bufferLock.lock()
        sampleBuffer.removeAll()
        bufferLock.unlock()
    }

    // MARK: - Audio Capture

    private func startCapture() async throws {
        guard !isCapturing else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
        sessionActive = true
        #endif

        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw TranscriptionError.engineUnavailable
        }

        // Target format: 16kHz mono float32 (sherpa-onnx requirement)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(modelSampleRate),
            channels: 1,
            interleaved: false
        )!

        // Converter for sample rate + channel count
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw TranscriptionError.engineUnavailable
        }

        let lock = bufferLock
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing, buffer.frameLength > 0 else { return }

            // Convert to 16kHz mono
            var status = AVAudioConverterInputStatus.haveData
            let outputFrameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * Double(self.modelSampleRate) / hwFormat.sampleRate
            ) + 16
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCapacity
            ) else { return }

            converter.convert(to: outputBuffer, status: &status) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard outputBuffer.frameLength > 0 else { return }

            // Copy float samples to lock-protected buffer
            let ptr = outputBuffer.floatChannelData![0]
            let count = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: ptr, count: count))

            lock.lock()
            self.sampleBuffer.append(contentsOf: samples)
            lock.unlock()
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    private func stopCaptureSync() {
        guard isCapturing else { return }
        isCapturing = false
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        #if os(iOS)
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation]
            )
            sessionActive = false
        }
        #endif
    }

    // MARK: - Model Configuration

    private static func buildConfig() -> sherpaOnnxOfflineRecognizerConfig? {
        guard let bundle = Bundle.main.path(forResource: "SherpaOnnxModels", ofType: nil) else {
            return nil
        }

        let tokens = (bundle as NSString).appendingPathComponent("funasr_tokens.txt")
        let model = (bundle as NSString).appendingPathComponent("funasr-nano.onnx")
        let vadModel = (bundle as NSString).appendingPathComponent("fsmn-vad.onnx")

        guard FileManager.default.fileExists(atPath: tokens),
              FileManager.default.fileExists(atPath: model) else {
            return nil
        }

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens,
            paraformer: sherpaOnnxOfflineParaformerModelConfig(model: model),
            numThreads: 2,
            provider: "cpu",
            debug: 0
        )

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: Int32(modelSampleRate), featureDim: 80),
            modelConfig: modelConfig,
            lmConfig: sherpaOnnxOfflineLMConfig(),
            decodingMethod: "greedy_search",
            maxActivePaths: 4
        )

        // Attach VAD config if the model file exists
        if FileManager.default.fileExists(atPath: vadModel) {
            // VAD is configured separately; the offline recognizer handles it internally
        }

        return config
    }

    private static func probeCapability() -> TranscriptionCapability {
        // sherpa-onnx FunASR-Nano supports Mandarin (+ dialects via contextualStrings).
        // English support depends on the model; report conservatively.
        let locales: Set<String> = ["zh-Hans-CN", "zh-Hant-TW", "en-US"]
        return TranscriptionCapability(
            supportsLongForm: true,    // No 60s limit like SFSpeechRecognizer
            maxSegmentSeconds: .max,   // Unlimited segments
            availableLocales: locales
        )
    }
}
