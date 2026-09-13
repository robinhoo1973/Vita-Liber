import Foundation

/// FR17.15：针对实际随包权重的能力目录。覆盖声明不是本应用医疗金样准确率。
public struct ASRModelDescriptor: Sendable, Equatable {
    public let choice: VoiceEngineChoice
    public let version: String
    public let license: String
    public let streamsNatively: Bool
    public let supportsHotwords: Bool
    public let languageCodes: [String]
    public let dialectLocales: [String]

    public func languageCode(for locale: String) -> String? {
        let normalized = TranscriptionLocale.normalizedIdentifier(locale)
        if ASRModelCatalog.dialectLocales.contains(normalized) {
            guard dialectLocales.contains(where: { TranscriptionLocale.normalizedIdentifier($0) == normalized }) else { return nil }
            return normalized.hasPrefix("yue") ? "yue" : "zh"
        }
        guard let code = normalized.split(separator: "-").first.map(String.init), languageCodes.contains(code) else { return nil }
        return code
    }

    /// 解码语言提示：`nil` = 该模型不支持此 locale；`""` = 不注入语言（启用模型自带 LID，或该引擎无此协议）。
    /// qwen3 只认官方名称（Chinese/Cantonese/English…，模型卡）；上游 sherpa 把 `"language " + 值` 原样编码进
    /// 解码提示，传 ISO 码等于强制一个训练分布外的标签（round2 A-N1 根因）。whisper 的 config.language 走 ISO 码。
    public func decoderLanguage(for locale: String, mode: TranscriptionLanguageMode) -> String? {
        guard let code = languageCode(for: locale) else { return nil }
        switch choice {
        case .qwen3: return mode == .mixed ? "" : ASRModelCatalog.qwenLanguageName(forCode: code)
        case .whisper: return code
        case .zipformer, .dolphin, .auto, .advanced, .dictation, .classic: return ""
        }
    }

    public var availableLocales: Set<String> {
        var locales = Set(languageCodes)
        if languageCodes.contains("zh") { locales.formUnion(["zh-Hans-CN", "zh-Hant-TW"]) }
        if languageCodes.contains("en") { locales.insert("en-US") }
        locales.formUnion(dialectLocales)
        return locales
    }
}

public enum ASRModelCatalog {
    static let dialectLocales: Set<String> = ["yue-hant-hk", "yue-hans-cn", "nan-tw", "wuu-cn", "zh-hans-cn-sichuan"]

    public static let models: [ASRModelDescriptor] = [
        .init(choice: .qwen3, version: "0.6B-int8-2026-03-25", license: "Apache-2.0", streamsNatively: false,
              supportsHotwords: true,
              languageCodes: "zh en yue ar de fr es pt id it ko ru th vi ja tr hi ms nl sv da fi pl cs fil fa el hu mk ro".split(separator: " ").map(String.init),
              dialectLocales: ["yue-Hant-HK", "yue-Hans-CN", "nan-TW", "wuu-CN", "zh-Hans-CN-Sichuan"]),
        .init(choice: .zipformer, version: "2023-02-20", license: "Apache-2.0", streamsNatively: true,
              supportsHotwords: true, languageCodes: ["zh", "en"], dialectLocales: []),
        // 此导出仅含CTC分支，不提供完整Dolphin的语言/地区检测API。
        .init(choice: .dolphin, version: "small-ctc-int8-2025-04-02", license: "Apache-2.0", streamsNatively: false,
              supportsHotwords: false,
              languageCodes: ["zh", "ja", "th", "ru", "ko", "id", "vi", "hi", "ur", "ms", "uz", "ar", "fa", "bn", "ta", "te", "ug", "gu", "my", "tl", "kk", "or", "ne", "mn", "km", "jv", "lo", "si", "fil", "ps", "pa", "kab", "ba", "ks", "tg", "su", "mr", "ky", "az"],
              dialectLocales: ["yue-Hant-HK", "yue-Hans-CN", "nan-TW", "wuu-CN", "zh-Hans-CN-Sichuan"]),
        // small多语模型的99个语言token；独立yue是large-v3新增，不能混用能力表。
        .init(choice: .whisper, version: "small-int8-2024-07-13", license: "MIT", streamsNatively: false,
              supportsHotwords: false,
              languageCodes: "en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su".split(separator: " ").map(String.init),
              dialectLocales: []),
    ]

    public static func model(for choice: VoiceEngineChoice) -> ASRModelDescriptor? {
        models.first { $0.choice == choice }
    }

    /// Qwen C API要求ASCII逗号；512总token窗口下保留完整短语，限制提示词占用。
    public static func qwenHotwords(_ values: [String]) -> String {
        var result: [String] = [], byteCount = 0
        for term in values {
            let clean = term.components(separatedBy: CharacterSet(charactersIn: ",，\n\r"))
                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, result.count < 24, byteCount + clean.utf8.count + 1 <= 512 else { continue }
            result.append(clean); byteCount += clean.utf8.count + 1
        }
        return result.joined(separator: ",")
    }

    /// Qwen3-ASR 官方语言名称表（模型卡 30 语种；中文各方言归 Chinese，粤语独立为 Cantonese）。
    /// 解码提示只能用这些名称：模型输出/提示格式为 `language <Name><asr_text>`。
    public static func qwenLanguageName(forCode code: String) -> String? {
        let names: [String: String] = [
            "zh": "Chinese", "en": "English", "yue": "Cantonese", "ar": "Arabic", "de": "German", "fr": "French",
            "es": "Spanish", "pt": "Portuguese", "id": "Indonesian", "it": "Italian", "ko": "Korean", "ru": "Russian",
            "th": "Thai", "vi": "Vietnamese", "ja": "Japanese", "tr": "Turkish", "hi": "Hindi", "ms": "Malay",
            "nl": "Dutch", "sv": "Swedish", "da": "Danish", "fi": "Finnish", "pl": "Polish", "cs": "Czech",
            "fil": "Filipino", "fa": "Persian", "el": "Greek", "hu": "Hungarian", "mk": "Macedonian", "ro": "Romanian"]
        return names[code]
    }

    /// 完整解码模型优先：英语/外语同样由 Qwen3 承担（zipformer 为中文主导的双语流式模型，英语 WER 显著更高；
    /// round2 A-N5）。Qwen3 不覆盖的语种依次交给 zipformer / dolphin（亚洲语种 CTC，小而快）/ whisper。
    /// 随包资产缺件时的回落由 `TranscriptionEngineBuilder.automaticChoice` 门控（Domain 不读 Bundle）。
    public static func automaticChoice(locale: String) -> VoiceEngineChoice {
        if model(for: .qwen3)?.languageCode(for: locale) != nil { return .qwen3 }
        if model(for: .zipformer)?.languageCode(for: locale) != nil { return .zipformer }
        if model(for: .dolphin)?.languageCode(for: locale) != nil { return .dolphin }
        if model(for: .whisper)?.languageCode(for: locale) != nil { return .whisper }
        return .classic
    }
}
