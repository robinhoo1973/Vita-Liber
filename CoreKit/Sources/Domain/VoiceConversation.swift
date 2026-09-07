import Foundation

/// F19 关怀语音助手会话引擎（受限文法，非开放域）——Domain 纯函数状态机。
///
/// 与 F17 的分工：F17 是「按住说话」的单向听写（全用户），F19 是双向多轮
/// 会话（关怀模式专属），两者共用转写引擎但**不共享交互状态**。
///
/// 本层只做会话文法与决策；转写/播报经既有 TranscriptionEngine / TTS 端口注入。
/// FR19.9 边界：不做自由对话与医疗问答；不自动执行删除/剂量变更（BR-006）。

// MARK: - 指令文法白名单（FR19.2）

public enum VoiceCommand: String, Sendable, Equatable, CaseIterable {
    // 查询类
    case todayMeds            // 今天吃什么药
    case nextAppointment      // 下次预约
    case recentGlucose        // 最近血糖
    case stockRemaining       // 药还剩多少 / 阿司匹林还剩多少
    case stockLocation        // 阿司匹林放在哪
    case stockExpiry          // 阿司匹林什么时候过期
    case expiringSoon         // 哪些药快过期了
    case askMedicationTaken   // 时段服药确认：早上吃的药都吃了吗
    // 操作类
    case recordMetric         // 血压 148 92 心率 76
    case markTaken            // 我吃过阿司匹林了
    case recordQuestion       // 记一个问题：…
    case startCamera          // 我要拍病历
    // 导航类
    case openTimeline         // 打开时间轴
    case openSearch           // 搜索 X
    case goHome               // 回到首页
    // 会话类
    case repeatLast           // 再说一遍
    case louder               // 大声一点
    case yes                  // 是
    case no                   // 否
    case selectNumber         // 第 N 个
    case selectName           // 选项名
    case cancel               // 取消
    case exitSession          // 退出
    // 危险/受限（FR19.5）
    case callContact          // 帮我打给女儿
    case callEmergency120     // 帮我打 120
}

/// 第八轮全仓审查修复（死抽象清除）：VoiceCommandDangerLevel 四级枚举与
/// dangerLevel(_:) 分类函数「计算后从未被消费」——App/域/测试零引用；会话
/// 状态机对每条命令硬编码确认路由（.repeatingObject/.confirming），
/// isForbidden 又用独立词表拦截，「.forbidden」等级永不返回。确认策略的
/// 唯一事实源在状态机；保留分级分类只会让未来两处漂移（BR-006/FR19.5
/// 语义分裂）。已删除枚举与函数。

public enum VoiceIntent: Sendable, Equatable {
    case command(VoiceCommand)
    /// 记录类携带正文（如指标读数）
    case record(metricText: String)
    /// 问诊速记携带正文（FR10.5）——与 recordMetric 分离：第六轮全仓审查
    /// 修复——原实现把 recordQuestion 折叠进 .record(metricText:)，
    /// step 硬编码 pendingCommand = .recordMetric：确认的问题速记被当
    /// 指标解析（可伪造 C 级读数）或静默丢弃，问诊列表永不可达。
    case recordQuestion(text: String)
    case unrecognized
}

/// FR19.2 指令文法解析（正则白名单，非开放域）。
/// 命中歧义（一句话命中多个计划/联系人）不在此层裁决——解析只报「候选>1」，
/// 列选循环由会话状态机负责（FR19.4：≤3 项编号列选）。
public enum VoiceCommandGrammar {

    /// 命令词词汇表（单一事实源）：App 键盘降级输入的快捷词必须与文法
    /// 解析同源——此处定义的词即文法接受的词（F19 词汇表归 Domain，
    /// App 层不得自建第二份拷贝）。
    public static let confirmWord = "确认"
    public static let cancelWord = "取消"
    public static func ordinalWord(_ n: Int) -> String? {
        let words = ["第一个", "第二个", "第三个"]
        guard n >= 1 && n <= words.count else { return nil }
        return words[n - 1]
    }

    struct Pattern: Sendable {
        let command: VoiceCommand
        let regex: String
    }

    static let patterns: [Pattern] = [
        Pattern(command: .todayMeds, regex: #"^(?:今天|现在)?(?:吃|有)?(?:什么|哪些)药"#),
        Pattern(command: .nextAppointment, regex: #"下次预约"#),
        Pattern(command: .recentGlucose, regex: #"最近(?:的)?血糖"#),
        Pattern(command: .stockRemaining, regex: #"(.{1,20})?(?:药)?还(?:剩|有)多(?:少|久)"#),
        Pattern(command: .stockLocation, regex: #"(.{1,20})放(?:在|的)?(?:哪|什么地方)"#),
        Pattern(command: .stockExpiry, regex: #"(.{1,20})什么时候(?:过|到)期"#),
        Pattern(command: .expiringSoon, regex: #"(?:哪些|什么)药(?:快|要)过期"#),
        Pattern(command: .askMedicationTaken, regex: #"(早上|中午|晚上|睡前)的?药(?:都)?吃(?:了)?吗"#),
        Pattern(command: .recordMetric, regex: #"^(?:血压|血糖|心率|体温|血氧|体重)[\s\d.点/／]+"#),
        Pattern(command: .markTaken, regex: #"我(?:吃|服用|已经吃)过?.{1,20}"#),
        Pattern(command: .recordQuestion, regex: #"^(?:记|记录)一个?(?:问题|下)[:：]?"#),
        Pattern(command: .startCamera, regex: #"(?:我)?(?:要|想)(?:拍|扫描)(?:病历|报告|处方|资料)"#),
        Pattern(command: .openTimeline, regex: #"打开时间轴"#),
        Pattern(command: .openSearch, regex: #"^(?:搜索|找)(.+)$"#),
        Pattern(command: .goHome, regex: #"回(?:到)?首页"#),
        Pattern(command: .repeatLast, regex: #"^(?:再说一遍|重复|没听清)"#),
        Pattern(command: .louder, regex: #"大声一点"#),
        Pattern(command: .yes, regex: #"^(?:是|对|好的|确认|嗯)"#),
        Pattern(command: .no, regex: #"^(?:否|不是|不对|取消)"#),
        Pattern(command: .selectNumber, regex: #"^(?:第)?([一二三123])个?"#),
        Pattern(command: .cancel, regex: #"取消"#),
        Pattern(command: .exitSession, regex: #"退出"#),
        // 评审修正第二轮（BR-012 急救语义词）：号码文法要求「打/拨打+号码」形态，
        // 单说「急救/救命/叫救护车/打救护车」此前无任何命中 → unrecognized（或被
        // callContact 抢先），急救出口经语音不可达。语义词直连 callEmergency120
        // （会话层仍走高危确认）——必须排在 callContact **之前**，否则「打救护车」
        // 被泛化联系人文法抢先。
        Pattern(command: .callEmergency120, regex: #"^(?:急救|救命)|(?:帮我)?(?:叫|打|拨打)救护车"#),
        Pattern(command: .callContact, regex: #"(?:帮我)?(?:打|打给|拨打)(.+)"#),
        // 审查修复：急救号码不再写死 120——按语言区域注入（120/119/911），
        // 动态正则见 parse(_:emergencyNumber:)
    ]

    public static func parse(_ transcript: String, emergencyNumber: String = "120") -> VoiceIntent {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unrecognized }
        // 急救号码按语言区域匹配（仅数字，天然无正则元字符）：必须先于通用
        // callContact 文法——「帮我打119」会被 (?:帮我)?(?:打|打给|拨打)(.+)
        // 抢先命中成泛化联系人拨号，注入号码的急救拨号契约形同虚设
        // （CI 34020363188 实证）。锚定句尾防「记录119条」误命中。
        // 评审修正第二轮：句尾锚定前先剥离常见句尾标点——转写引擎常补「。/！？」
        // 使「拨打120。」失配并回落泛化联系人拨号（急救契约静默丢失）。
        let emergencyText = text.trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?，,."))
        let emergencyDigits = emergencyNumber.filter(\.isNumber)
        if !emergencyDigits.isEmpty {
            let regex: NSRegularExpression?
            do { regex = try NSRegularExpression(pattern: "(?:帮我)?(?:打|打给|拨打)\\s*\(emergencyDigits)\\s*$") }
            catch { regex = nil }   // 注入号码非纯数字的极端情形：回落通用文法（文法表由本仓维护）
            if let regex {
                let range = NSRange(emergencyText.startIndex..<emergencyText.endIndex, in: emergencyText)
                if regex.firstMatch(in: emergencyText, range: range) != nil {
                    return .command(.callEmergency120)
                }
            }
        }
        for pattern in patterns {
            // 不用 try?（tech-spec §7 红线）；文法表由本仓维护，
            // 编译失败属维护错误——显式跳过并保持白名单其余条目可用。
            let regex: NSRegularExpression
            do { regex = try NSRegularExpression(pattern: pattern.regex) }
            catch { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                if pattern.command == .recordMetric {
                    return .record(metricText: text)
                }
                if pattern.command == .recordQuestion {
                    let body = text.replacingOccurrences(of: #"^(?:记|记录)一个?(?:问题|下)[:：]?\s*"#,
                                                         with: "", options: .regularExpression)
                    return .recordQuestion(text: body.isEmpty ? text : body)
                }
                return .command(pattern.command)
            }
        }
        return .unrecognized
    }

    /// FR19.5 删除/剂量变更：语音通道**一律拒绝**——无论怎么表述。
    /// 词表命中即拒（安全侧偏置：误拒优于误执行）。
    public static func isForbidden(_ transcript: String) -> Bool {
        let forbidden = ["删除", "删掉", "移除", "改剂量", "调剂量", "剂量改",
                         "改成一天", "停用", "停药", "取消这个药"]
        return forbidden.contains { transcript.contains($0) }
    }
}

// MARK: - 会话状态机（FR19.4 选择循环 / FR19.5 分级确认 / FR19.6 超时）

public enum ConversationPhase: String, Sendable, Equatable {
    case listening        // 等待指令
    case selecting        // 编号列选（≤3）
    case confirming       // 分级确认中
    case repeatingObject  // 拨号前复述对象（FR19.5）
    case ended
}

public struct ConversationState: Sendable, Equatable {
    public var phase: ConversationPhase = .listening
    public var options: [String] = []          // 当前列选（≤3）
    public var pendingCommand: VoiceCommand?
    public var pendingObject: String?          // 复述对象名
    public var silentRounds = 0                // 连续无效应答轮数（FR19.6）
    public var lastPrompt: SpeechPrompt? = nil   // 重播源（再说一遍）
    public init() {}
}

public enum ConversationEvent: Sendable, Equatable {
    case speak(SpeechPrompt)          // 需要播报（V3.68：提示语类型化，App 经 L10n 渲染）
    case askOptions([String])         // 需要列选（≤3）
    case requireRepeatObject(String)  // 需要复述对象（拨号前）
    case execute(VoiceCommand, payload: String?)   // 可执行的低风险动作
    case rejectForbidden              // 删除/剂量变更拒绝卡
    case exitGracefully               // 礼貌退出（超时/两轮无应答）
}

/// V3.68 语音提示语（类型化：Domain 不再拼中文句式；App 层经
/// L10n.voicePromptText 渲染，BR-006 措辞负清单在模板层保证）。
public enum SpeechPrompt: Sendable, Equatable {
    case repeatHint                       // 没听清，再说一遍/退出
    case pickOption                       // 请说第一到第三个中的一个
    case optionNotFound                   // 没找到这个选项
    case callConfirm(target: String)      // 将拨打 X
    case markTakenConfirm(object: String) // 标记 X 已服用
    case forbiddenHint                    // 语音通道不能删除/修改剂量
    case recordConfirm(metricText: String)
    case sayCallTargetAgain
    case cancelled
    case confirmToCall
    case confirmToSave
    case multipleMatches(options: [String])
}

/// F19 会话规则引擎（纯函数：输入 = 现有状态 + 转写，输出 = 事件 + 新状态）
public enum VoiceConversationEngine {

    public static let maxSilentRounds = 2          // FR19.6
    public static let maxOptions = 3               // FR19.4

    public static func step(state: ConversationState, transcript: String,
                           emergencyNumber: String = "120") -> (state: ConversationState, events: [ConversationEvent]) {
        var s = state
        var events: [ConversationEvent] = []
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // FR19.5 第一优先：删除/剂量变更一律拒绝（无论当前相位）
        if VoiceCommandGrammar.isForbidden(text) {
            events.append(.rejectForbidden)
            s.phase = .listening
            s.silentRounds = 0
            s.lastPrompt = .forbiddenHint
            events.append(.speak(.forbiddenHint))
            return (s, events)
        }

        // FR19.4：任何步骤「再说一遍」= 完整重播当前问题与选项
        if text.contains("再说一遍") || text.contains("重复") {
            if let lastPrompt = s.lastPrompt {
                events.append(.speak(lastPrompt))
            }
            if s.phase == .selecting, !s.options.isEmpty {
                events.append(.askOptions(s.options))
            }
            return (s, events)
        }

        switch s.phase {
        case .listening, .selecting:
            let intent = VoiceCommandGrammar.parse(text, emergencyNumber: emergencyNumber)
            switch intent {
            case .unrecognized:
                s.silentRounds += 1
                if s.silentRounds >= maxSilentRounds {
                    events.append(.exitGracefully)
                    s.phase = .ended
                } else {
                    s.lastPrompt = .repeatHint
                    events.append(.speak(.repeatHint))
                }
            case .command(let c):
                switch c {
                case .selectNumber where s.phase == .selecting:
                    // 第 N 个 → 选项执行
                    let index = numberIndex(text) ?? 0
                    guard index >= 0 && index < s.options.count else {
                        events.append(.speak(.pickOption))
                        return (s, events)
                    }
                    let chosen = s.options[index]
                    events.append(.execute(s.pendingCommand ?? .todayMeds, payload: chosen))
                    s.phase = .listening; s.options = []; s.silentRounds = 0
                case .selectName where s.phase == .selecting:
                    let matched = s.options.first { text.contains($0) || $0.contains(text) }
                    guard let chosen = matched else {
                        events.append(.speak(.optionNotFound))
                        return (s, events)
                    }
                    events.append(.execute(s.pendingCommand ?? .todayMeds, payload: chosen))
                    s.phase = .listening; s.options = []; s.silentRounds = 0
                case .yes, .no:
                    handleYesNo(&s, &events, yes: c == .yes)
                case .exitSession, .cancel:
                    events.append(.exitGracefully)
                    s.phase = .ended
                case .callContact:
                    // FR19.5：必须复述对象再确认
                    let object = extractObject(text, after: "打")
                    s.phase = .repeatingObject
                    s.pendingCommand = .callContact
                    s.pendingObject = object
                    let target = object.isEmpty ? "" : object
                    s.lastPrompt = .callConfirm(target: target)
                    events.append(.requireRepeatObject(object))
                    events.append(.speak(.callConfirm(target: target)))
                case .callEmergency120:
                    // 审查修复：号码按语言区域注入（120/119/911），不再写死 120
                    s.phase = .repeatingObject
                    s.pendingCommand = .callEmergency120
                    s.pendingObject = emergencyNumber
                    s.lastPrompt = .callConfirm(target: emergencyNumber)
                    events.append(.requireRepeatObject(emergencyNumber))
                    events.append(.speak(.callConfirm(target: emergencyNumber)))
                case .markTaken:
                    // FR19.5：标记服药 = 写操作，单次口头确认（BR-004 同语义）
                    let object = extractMarkTakenObject(text)
                    s.phase = .confirming
                    s.pendingCommand = .markTaken
                    s.pendingObject = object
                    s.lastPrompt = .markTakenConfirm(object: object)
                    events.append(.speak(.markTakenConfirm(object: object)))
                case .stockExpiry, .stockRemaining, .stockLocation:
                    // 库存查询载荷 = 句首药品名（「阿司匹林还剩多少/什么时候过期/
                    // 放在哪」）——此前 extractPayload 只剥「搜索/找」前缀，库存
                    // 指令载荷恒 nil，视图回全局清单答非所问
                    events.append(.execute(c, payload: extractStockObject(text)))
                    s.phase = .listening
                    s.silentRounds = 0
                default:
                    // 低风险查询/导航：直接执行
                    events.append(.execute(c, payload: extractPayload(text)))
                    s.phase = .listening
                    s.silentRounds = 0
                }
            case .record(let metricText):
                // 写操作（记录类）：单次口头确认（BR-004 同语义）
                s.phase = .confirming
                s.pendingCommand = .recordMetric
                s.pendingObject = metricText
                s.lastPrompt = .recordConfirm(metricText: metricText)
                events.append(.speak(.recordConfirm(metricText: metricText)))
            case .recordQuestion(let questionText):
                // FR10.5 问诊速记：单次口头确认后落问诊列表（独立指令，
                // 不与 recordMetric 混流）
                s.phase = .confirming
                s.pendingCommand = .recordQuestion
                s.pendingObject = questionText
                s.lastPrompt = .recordConfirm(metricText: questionText)
                events.append(.speak(.recordConfirm(metricText: questionText)))
            }
        case .repeatingObject:
            let intent = VoiceCommandGrammar.parse(text, emergencyNumber: emergencyNumber)
            switch intent {
            case .command(.yes):
                guard let object = s.pendingObject else {
                    s.phase = .listening
                    events.append(.speak(.sayCallTargetAgain))
                    return (s, events)
                }
                events.append(.execute(s.pendingCommand ?? .callContact, payload: object))
                s.phase = .listening; s.pendingObject = nil; s.silentRounds = 0
            case .command(.no), .command(.cancel):
                s.phase = .listening; s.pendingObject = nil; s.silentRounds = 0
                events.append(.speak(.cancelled))
            default:
                s.silentRounds += 1
                events.append(.speak(.confirmToCall))
            }
        case .confirming:
            // 确认相位只认 是/否/取消；其余一律视为未听清（不计入危险误执行）
            switch VoiceCommandGrammar.parse(text, emergencyNumber: emergencyNumber) {
            case .command(.yes):
                handleYesNo(&s, &events, yes: true)
            case .command(.no), .command(.cancel):
                handleYesNo(&s, &events, yes: false)
            default:
                s.silentRounds += 1
                events.append(.speak(.confirmToSave))
            }
        case .ended:
            break
        }
        return (s, events)
    }

    private static func handleYesNo(_ s: inout ConversationState,
                                    _ events: inout [ConversationEvent], yes: Bool) {
        switch s.phase {
        case .confirming:
            if yes {
                events.append(.execute(s.pendingCommand ?? .recordMetric, payload: s.pendingObject))
            } else {
                events.append(.speak(.cancelled))
            }
            s.phase = .listening; s.pendingObject = nil; s.silentRounds = 0
        default:
            break
        }
    }

    /// 列选提示（FR19.4）：≤3 项，编号 + 逐个朗读
    public static func optionsPrompt(_ options: [String], pendingCommand: VoiceCommand? = nil) -> (state: ConversationState, events: [ConversationEvent]) {
        let trimmed = Array(options.prefix(maxOptions))
        var s = ConversationState()
        s.phase = .selecting
        s.options = trimmed
        // 第六轮全仓审查修复：原实现新开空 ConversationState，pendingCommand
        // 丢失——列选执行时 `pendingCommand ?? .todayMeds` 恒回落今天吃药，
        // 用户选中的查询项（如库存）永远执行成错误指令
        s.pendingCommand = pendingCommand
        s.lastPrompt = .multipleMatches(options: trimmed)
        return (s, [.askOptions(trimmed), .speak(.multipleMatches(options: trimmed))])
    }

    private static func numberIndex(_ text: String) -> Int? {
        let map: [Character: Int] = ["一": 1, "二": 2, "三": 3, "1": 1, "2": 2, "3": 3]
        for (ch, v) in map where text.contains(ch) { return v - 1 }
        return nil
    }

    private static func extractObject(_ text: String, after keyword: String) -> String {
        guard let r = text.range(of: keyword) else { return "" }
        var object = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥掉连接词前缀（打给/拨打给/给）——「帮我打给女儿」的对象是「女儿」，
        // 不是「给女儿」（复述对象必须是人名本身）
        for prefix in ["给"] where object.hasPrefix(prefix) {
            object = String(object.dropFirst(prefix.count))
        }
        return object
    }

    /// 「我吃过阿司匹林了」→ 提取药名（剥掉动作词与句尾语气词）
    private static func extractMarkTakenObject(_ text: String) -> String {
        var object = text
        for word in ["我已经", "已经", "我吃过", "我吃了", "我服用过", "我服用了", "我吃", "我服用"] {
            if object.hasPrefix(word) { object = String(object.dropFirst(word.count)) }
        }
        object = object.replacingOccurrences(of: "了。", with: "")
            .replacingOccurrences(of: "了", with: "")
        return object.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 库存类指令载荷：在最早的动词边界（还/放/什么时候）截断，句首即药品名。
    /// 词表与 patterns 逐条对齐（(?:药)? 前缀 → 「药」是泛化问句；放(?:在|的)?
    /// 直连哪/什么地方 → 必须收「放哪/放什么地方」两形）。
    /// 泛化药词（「药/我的药」等）与无边界（纯列表问句）返回 nil。
    private static func extractStockObject(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutWords = ["什么时候", "还剩", "还有", "剩多", "放在", "放的", "放哪", "放什么地方"]
        guard let earliest = cutWords.compactMap({ t.range(of: $0)?.lowerBound }).min() else { return nil }
        let object = String(t[..<earliest]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !object.isEmpty else { return nil }
        // 泛化药词过滤：patterns 的 (?:药)? 使「药还剩多少/药放在哪」命中
        // 库存指令——载荷「药」不是药名，按药名匹配会误报「未找到」或
        // 命中首个含「药」字的药品（答非所问）。泛化问句回落全清单。
        let genericWords = ["药", "药品", "药片", "药丸", "我的药", "这个药", "那个药"]
        return genericWords.contains(object) ? nil : object
    }

    private static func extractPayload(_ text: String) -> String? {
        // 第六轮全仓审查修复：搜索类指令带载荷（搜索词）——原实现恒 nil，
        // 「搜索阿司匹林」确认后执行 .openSearch 却丢弃查询词，搜索页
        // 空开。载荷剥离文法前缀（与 patterns 单一事实源同一词表）。
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["搜索", "找"] where t.hasPrefix(prefix) {
            let body = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }
        return nil   // 其余导航/查询类无载荷
    }
}
