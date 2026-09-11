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

    public static func automaticChoice(locale: String) -> VoiceEngineChoice {
        let normalized = TranscriptionLocale.normalizedIdentifier(locale)
        if dialectLocales.contains(normalized) || normalized == "zh" || normalized.hasPrefix("zh-") || normalized == "yue" { return .qwen3 }
        if model(for: .zipformer)?.languageCode(for: locale) != nil { return .zipformer }
        if model(for: .whisper)?.languageCode(for: locale) != nil { return .whisper }
        if model(for: .dolphin)?.languageCode(for: locale) != nil { return .dolphin }
        return .classic
    }
}
