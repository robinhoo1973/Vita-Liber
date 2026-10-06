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
        // 方言只在描述符自带的方言覆盖内按「粤语→yue / 其余→zh」解析（2026-10-05 目录驱动：
        // 覆盖表来自目录 JSON 的 families[].dialects）；未列方言的家族对 dialect locale 无覆盖。
        if dialectLocales.contains(where: { TranscriptionLocale.normalizedIdentifier($0) == normalized }) {
            return normalized.hasPrefix("yue") ? "yue" : "zh"
        }
        guard let code = normalized.split(separator: "-").first.map(String.init), languageCodes.contains(code) else { return nil }
        return code
    }

    /// 解码语言提示：`nil` = 该模型不支持此 locale；`""` = 不注入语言（启用模型自带 LID，或该引擎无此协议）。
    /// qwen3 只认官方名称（Chinese/Cantonese/English…，模型卡）；上游 sherpa 把 `"language " + 值` 原样编码进
    /// 解码提示，传 ISO 码等于强制一个训练分布外的标签（round2 A-N1 根因）。whisper 的 config.language 走 ISO 码，
    /// 空串 = 交 sherpa whisper 自带语种自动检测（2026-10-05 业主反馈修复批：此前 whisper 混说仍强制主语言，
    /// 与 FR17.15「混说 = 不强制语言」合同冲突）。
    public func decoderLanguage(for locale: String, mode: TranscriptionLanguageMode) -> String? {
        guard let code = languageCode(for: locale) else { return nil }
        switch choice {
        case .qwen3: return mode == .mixed ? "" : ASRModelCatalog.qwenLanguageName(forCode: code)
        case .whisper: return mode == .mixed ? "" : code
        case .zipformer, .dolphin, .auto, .advanced, .dictation, .classic,
             .senseVoice, .fireRed, .moonshine: return ""
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
    /// 2026-10-05 业主裁定：模型信息（家族集/档位/名称/简介/语言覆盖/方言覆盖/版本/license）
    /// **全部**由 CI 生成的签名目录 JSON 提供，本枚举不再内置任何模型数据——
    /// 以下函数均以 `ASRModelReleaseIndex` 为输入（Domain 纯函数，索引由
    /// Infrastructure 从信任库取 currentIndex ?? 随包基线）。
    ///
    /// 仍保留的静态表只属于**引擎协议知识**（与模型数据无关）：qwen3 官方语言名
    /// 编码表、热词 CSV 编码、以及「哪类引擎支持热词/原生流式」的能力事实。

    /// 引擎能力事实：支持热词的引擎（qwen3/zipformer 装配热词协议，其余无此协议）。
    public static func supportsHotwords(_ choice: VoiceEngineChoice) -> Bool {
        choice == .qwen3 || choice == .zipformer
    }

    /// 引擎能力事实：原生流式（在线 transducer 分支，其余走离线分段 + VAD）。
    public static func streamsNatively(_ choice: VoiceEngineChoice) -> Bool {
        choice == .zipformer
    }

    /// 目录驱动描述符表：按目录 families 发布序（= auto 链优先序，CI 所有）展开；
    /// 旧目录缺 families 段时按 models 唯一 id 派生（语言覆盖为空 → auto 链回落 classic）。
    /// 家族 id 不可解析为引擎档（新目录对旧 App）或非随包档 → 跳过。
    public static func descriptors(from index: ASRModelReleaseIndex?) -> [ASRModelDescriptor] {
        guard let index else { return [] }
        let families: [ASRModelFamily]
        if let declared = index.families {
            families = declared
        } else {
            var seen = Set<String>()
            families = index.models.reduce(into: []) { result, release in
                guard !seen.contains(release.id) else { return }
                seen.insert(release.id)
                result.append(ASRModelFamily(id: release.id))
            }
        }
        var result: [ASRModelDescriptor] = []
        for family in families {
            guard let choice = VoiceEngineChoice(rawValue: family.id), choice.isBundledModel else { continue }
            let entries = index.models.filter { $0.id == family.id }
            // max(by:) 谓词 `isNewer($1, than: $0)` = 升序取末位 = 最新版本；
            // max 为 nil 当且仅当 entries 为空,`?? entries.first?.version` 恒不命中(2026-10-05 审查)。
            let version = entries.map(\.version).max { ASRVersion.isNewer($1, than: $0) } ?? ""
            let license = entries.compactMap(\.license).first ?? ""
            result.append(ASRModelDescriptor(
                choice: choice,
                version: version,
                license: license,
                streamsNatively: streamsNatively(choice),
                supportsHotwords: supportsHotwords(choice),
                languageCodes: family.languages ?? [],
                dialectLocales: family.dialects ?? []))
        }
        return result
    }

    public static func model(for choice: VoiceEngineChoice, in index: ASRModelReleaseIndex?) -> ASRModelDescriptor? {
        descriptors(from: index).first { $0.choice == choice }
    }

    /// 方言 locale 并集（平台轨能力判定用——方言 locale 不得按语言码前缀回落）。
    public static func dialectLocales(in index: ASRModelReleaseIndex?) -> Set<String> {
        Set(descriptors(from: index).flatMap(\.dialectLocales).map(TranscriptionLocale.normalizedIdentifier))
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

    /// 完整解码模型优先：按目录 families 发布序（CI 所有 = 质量/能力优先序，
    /// 以签名目录为准；2026-10-05 目录化后不再有 App 内模板序）取第一个覆盖该 locale 的模型。
    /// 随包资产缺件时的回落由 `TranscriptionEngineBuilder.automaticChoice` 门控（Domain 不读 Bundle）。
    public static func automaticChoice(locale: String, in index: ASRModelReleaseIndex?) -> VoiceEngineChoice {
        for model in descriptors(from: index) where model.languageCode(for: locale) != nil {
            return model.choice
        }
        return .classic
    }

    /// FR17.15（2026-10-05 业主反馈修复批）：混说模式的**多语种**引擎选择——
    /// 按目录序取第一个**覆盖全部已选语种**的模型。无模型全量覆盖时回落主语言单语种
    /// 逻辑（不因次要语种改变引擎——保持既有行为）。空列表回落 `.classic`
    /// （零资产基线轨，无主语言可依）。
    public static func automaticChoice(locales: [String], in index: ASRModelReleaseIndex?) -> VoiceEngineChoice {
        guard let primary = locales.first else { return .classic }
        for model in descriptors(from: index) where locales.allSatisfy({ model.languageCode(for: $0) != nil }) {
            return model.choice
        }
        return automaticChoice(locale: primary, in: index)
    }
}
