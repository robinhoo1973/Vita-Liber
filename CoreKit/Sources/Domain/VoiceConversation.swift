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

/// 危险分级（FR19.5）
public enum VoiceCommandDangerLevel: Int, Sendable, Comparable, Equatable {
    case low = 0        // 查询、导航、记录——至多单次口头确认
    case elevated = 1   // 标记服药等写操作——单次口头确认（BR-004）
    case high = 2       // 拨打联系人——必须复述对象再确认
    case forbidden = 3  // 删除/剂量变更——语音通道一律拒绝（BR-006）

    public static func < (lhs: VoiceCommandDangerLevel, rhs: VoiceCommandDangerLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum VoiceIntent: Sendable, Equatable {
    case command(VoiceCommand)
    /// 记录类携带正文（如指标读数/问题速记）
    case record(metricText: String)
    case unrecognized
}

/// FR19.2 指令文法解析（正则白名单，非开放域）。
/// 命中歧义（一句话命中多个计划/联系人）不在此层裁决——解析只报「候选>1」，
/// 列选循环由会话状态机负责（FR19.4：≤3 项编号列选）。
public enum VoiceCommandGrammar {

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
        Pattern(command: .callContact, regex: #"(?:帮我)?(?:打|打给|拨打)(.+)"#),
        Pattern(command: .callEmergency120, regex: #"(?:帮我)?打?120"#),
    ]

    public static func parse(_ transcript: String) -> VoiceIntent {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unrecognized }
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
                    return .record(metricText: body.isEmpty ? text : body)
                }
                return .command(pattern.command)
            }
        }
        return .unrecognized
    }

    public static func dangerLevel(_ intent: VoiceIntent) -> VoiceCommandDangerLevel {
        switch intent {
        case .command(let c):
            switch c {
            case .markTaken, .recordMetric, .recordQuestion: return .elevated
            case .callContact: return .high
            case .callEmergency120: return .high
            default: return .low
            }
        case .record: return .elevated
        case .unrecognized: return .low
        }
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
    public var lastPrompt: String = ""         // 重播源（再说一遍）
    public init() {}
}

public enum ConversationEvent: Sendable, Equatable {
    case speak(String)                // 需要播报（纯事实句式）
    case askOptions([String])         // 需要列选（≤3）
    case requireRepeatObject(String)  // 需要复述对象（拨号前）
    case execute(VoiceCommand, payload: String?)   // 可执行的低风险动作
    case rejectForbidden              // 删除/剂量变更拒绝卡
    case exitGracefully               // 礼貌退出（超时/两轮无应答）
}

/// F19 会话规则引擎（纯函数：输入 = 现有状态 + 转写，输出 = 事件 + 新状态）
public enum VoiceConversationEngine {

    public static let maxSilentRounds = 2          // FR19.6
    public static let maxOptions = 3               // FR19.4

    public static func step(state: ConversationState, transcript: String) -> (state: ConversationState, events: [ConversationEvent]) {
        var s = state
        var events: [ConversationEvent] = []
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // FR19.5 第一优先：删除/剂量变更一律拒绝（无论当前相位）
        if VoiceCommandGrammar.isForbidden(text) {
            events.append(.rejectForbidden)
            s.phase = .listening
            s.silentRounds = 0
            s.lastPrompt = "语音通道不能删除或修改剂量。请在屏幕上操作，或让家人协助。"
            events.append(.speak(s.lastPrompt))
            return (s, events)
        }

        // FR19.4：任何步骤「再说一遍」= 完整重播当前问题与选项
        if text.contains("再说一遍") || text.contains("重复") {
            if !s.lastPrompt.isEmpty {
                events.append(.speak(s.lastPrompt))
            }
            if s.phase == .selecting, !s.options.isEmpty {
                events.append(.askOptions(s.options))
            }
            return (s, events)
        }

        switch s.phase {
        case .listening, .selecting:
            let intent = VoiceCommandGrammar.parse(text)
            switch intent {
            case .unrecognized:
                s.silentRounds += 1
                if s.silentRounds >= maxSilentRounds {
                    events.append(.exitGracefully)
                    s.phase = .ended
                } else {
                    s.lastPrompt = "没听清，请再说一遍，或者说「退出」结束。"
                    events.append(.speak(s.lastPrompt))
                }
            case .command(let c):
                switch c {
                case .selectNumber where s.phase == .selecting:
                    // 第 N 个 → 选项执行
                    let index = numberIndex(text) ?? 0
                    guard index >= 0 && index < s.options.count else {
                        events.append(.speak("请说第一到第三个中的一个。"))
                        return (s, events)
                    }
                    let chosen = s.options[index]
                    events.append(.execute(s.pendingCommand ?? .todayMeds, payload: chosen))
                    s.phase = .listening; s.options = []; s.silentRounds = 0
                case .selectName where s.phase == .selecting:
                    let matched = s.options.first { text.contains($0) || $0.contains(text) }
                    guard let chosen = matched else {
                        events.append(.speak("没找到这个选项，请说选项的名字或第几个。"))
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
                    let prompt = "将拨打\(object.isEmpty ? "联系人" : "\(object)")，请说「确认」或「取消」。"
                    s.lastPrompt = prompt
                    events.append(.requireRepeatObject(object))
                    events.append(.speak(prompt))
                case .callEmergency120:
                    s.phase = .repeatingObject
                    s.pendingCommand = .callEmergency120
                    s.pendingObject = "120"
                    let prompt = "将拨打 120，请说「确认」或「取消」。"
                    s.lastPrompt = prompt
                    events.append(.requireRepeatObject("120"))
                    events.append(.speak(prompt))
                case .markTaken:
                    // FR19.5：标记服药 = 写操作，单次口头确认（BR-004 同语义）
                    let object = extractMarkTakenObject(text)
                    s.phase = .confirming
                    s.pendingCommand = .markTaken
                    s.pendingObject = object
                    let prompt = "标记\(object.isEmpty ? "该药" : object)已服用，对吗？请说「确认」或「取消」。"
                    s.lastPrompt = prompt
                    events.append(.speak(prompt))
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
                let prompt = "记录 \(metricText)。对吗？请说「确认」或「取消」。"
                s.lastPrompt = prompt
                events.append(.speak(prompt))
            }
        case .repeatingObject:
            let intent = VoiceCommandGrammar.parse(text)
            switch intent {
            case .command(.yes):
                guard let object = s.pendingObject else {
                    s.phase = .listening
                    events.append(.speak("请重新说出要拨打的对象。"))
                    return (s, events)
                }
                events.append(.execute(s.pendingCommand ?? .callContact, payload: object))
                s.phase = .listening; s.pendingObject = nil; s.silentRounds = 0
            case .command(.no), .command(.cancel):
                s.phase = .listening; s.pendingObject = nil; s.silentRounds = 0
                events.append(.speak("已取消。"))
            default:
                s.silentRounds += 1
                events.append(.speak("请说「确认」拨打，或「取消」。"))
            }
        case .confirming:
            // 确认相位只认 是/否/取消；其余一律视为未听清（不计入危险误执行）
            switch VoiceCommandGrammar.parse(text) {
            case .command(.yes):
                handleYesNo(&s, &events, yes: true)
            case .command(.no), .command(.cancel):
                handleYesNo(&s, &events, yes: false)
            default:
                s.silentRounds += 1
                events.append(.speak("请说「确认」保存，或「取消」。"))
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
                events.append(.speak("已取消。"))
            }
            s.phase = .listening; s.pendingObject = nil; s.silentRounds = 0
        default:
            break
        }
    }

    /// 列选提示（FR19.4）：≤3 项，编号 + 逐个朗读
    public static func optionsPrompt(_ options: [String]) -> (state: ConversationState, events: [ConversationEvent]) {
        let trimmed = Array(options.prefix(maxOptions))
        var s = ConversationState()
        s.phase = .selecting
        s.options = trimmed
        let numbered = trimmed.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: "，")
        s.lastPrompt = "找到多个匹配：\(numbered)。请说第几个，或说选项名。"
        return (s, [.askOptions(trimmed), .speak(s.lastPrompt)])
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

    private static func extractPayload(_ text: String) -> String? {
        nil   // 导航/查询类无载荷；载荷由装配层按指令另行解析
    }
}
