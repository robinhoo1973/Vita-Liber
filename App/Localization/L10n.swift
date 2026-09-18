import Foundation
import Domain   // ObservationKind 等枚举名映射（Domain 类型不上 UI，名称走本单出口）

/// **文案唯一出口**（tech-spec §3 / CLAUDE.md「Strings are zh-Hans + zh-Hant via L10n」）。
///
/// 纪律：视图里不得出现面向用户的中文字面量，一律经 `L10n.xxx`。
/// 每个 key 必须同时存在于 zh-Hans / zh-Hant / en 三个 .strings 文件——
/// 由 SU-M15-L10N 套件断言三文件键集一致（缺一即红）。
///
/// **当前范围（M1.5）**：nav 五项 + M1.5 新增文案已键化；M1a–M1c 的历史文案
/// 仍是内联字面量，属 §11 清偿项「L10n 硬编码」，按 dev-pm §8.6 归属 M1c 全量走查，
/// 实际滞留至今——本批建立机制与门禁，存量迁移随 M2 分批清偿。
/// 机制先于存量：没有单出口和键集门禁，边补边漏，永远收不了口。
enum L10n {

    // MARK: - 导航（ui-ux §9）
    // MARK: - 健康 Tab（H 重构；2026-09-15 实测修复批：占位页三个快捷卡与假搜索框退役，
    // 随之删除只服务它们的键：quickActions / trends / reminders / searchRecords /
    // searchPlaceholder / summaryTitle——保留的三键仍被健康 Tab 数据面消费）

    // MARK: - F7 趋势（SP-13 / FR7.2）
    /// 已排除点分段标题（带条数：数字是事实，用户据此判断影响范围）
    /// 已排除点分段内「在图中显示 / 从图中隐藏」动作（对照视图的显式开关；
    /// 原来挂在工具栏的模式按钮语义不清且位置远离它影响的数据）
    /// 本周期可见读数全部被排除时的事实句（否则图表区空白且无解释）

    // MARK: - FR17.13 标准语音输入模板
    // FR17.13 受限修改拒绝卡（V3.68：Domain 只出 category，文案本层组装）
    // FR13.8 配药清单 CSV 表头（V3.68：Domain 参数化，本层提供本地化表头）
    // FR5.5 文档类型标签（V3.68：从 Infrastructure 上移本层 L10n 化）
    // FR17.10/FR10.2 语音提醒澄清提示（两处调用共用，禁止各写一份字面量）

    // FR1.1 · V3.22 生物识别门禁（SP-01 锁屏遮罩）
    // BR-007/FR1.9 敏感媒体解锁理由（LocalAuthentication localizedReason）

    // MARK: - FR17.12 隐私与耳机须知

    // MARK: - FR13.11 iCloud 备份
    /// 第八轮修复：非校验类恢复失败（读文件/磁盘/约束/新版本 schema）——不归罪文件损坏
    // ADR-019：目标设备已有数据——恢复被整体拒绝（不静默覆盖/丢弃）
    // ADR-019 冲突预览：逐项裁决（保留本机/采用备份/并存）
    // FR13.4 导出前身份验证 + 隐私提醒 / FR13.5 恢复前确认 + 恢复后校验报告

    // SP-17 批次详情/编辑（ui-ux §5.22.1）
    // FR9.8.3 差异月报句式（V3.68：Domain 只出数值，本层渲染）
    // 关怀模式「生效参数」摘要区（M2 设置页；评审补——此前为视图内联中文字面量，
    // L0 [10/10] L10n 门禁真违规；迁入三文件后 zh-Hant/en 平价交付）
    /// 插值串（String(format:) 取 %ld；zh-Hans/Hant 的「长按 N 秒」骨架一致）

    // F19 会话提示语（V3.68：SpeechPrompt → 本层渲染）


    // FR14.1 分目的授权面板（ui-ux §5.22.2）
    // FR14.4 外观与主题（§5.12.1 / tech-spec §5.28.1）
    // 药名缺省词与动态 accessibilityLabel（评审补——此前为行内插值 + 中文字面量，
    // L0 [10/10] 门禁新判定器命中；模板用 %@，药名由调用方保证不含未转义 %）
    // FR12.5 七段模板句（V3.68：Domain 只出数据，模板本层渲染）
    // V3.70：来源行结构化对（Domain 不再拼中文全角括号——en/zh-Hant 各自句式）


    // 业主 2026-09-17 定：注册必要字段 = 特征性数据 + 紧急联系人；健康预填默认值
    /// 全仓审查 2026-09-18（F-A1-01）：建档落库失败警报（统一 saveFailedAlert 出口）
    /// 三部件版本：Version <Release> Build <CI序号> Code Hash <提交哈希>（FR22.8 / dev-pm §9.3）

    // MARK: - Pro 产出包

    /// 审查修正（F-A1）：成员写库失败警报（此前静默关单，见 MemberViews）


    /// 回读句式（FR17.13）：%@ = 已确认字段列表（App 层经字段标签映射组装，
    /// Domain 不再拼接句式——V3.68 §11 清偿残根修复）
    /// 计划保存失败告警（响亮失败：创建失败保留表单，不静默关 sheet）
    /// 预约保存失败告警（响亮失败：创建失败保留表单，不静默关 sheet）
    // 业主裁决 D2（2026-09-18）：F12 AI 助手永久退役——assistant.* 键已随
    // AssistantHistoryView/AssistantChatView 删除（保留 ai.* 模板键：AILocal 七段式在用）

        /// 全部已键化的 key（SU-M15-L10N 遍历断言的输入）。
    /// 新增 key 必须同步登记到这里——否则门禁扫不到，又回到「缺证据当有证据」。
    /// 参数化文案（避免把格式串散落视图）

    // MARK: - L10n 清偿批五 · SP-24 备份（FR13.2）

    // MARK: - L10n 清偿批五 · F7 趋势图轴与图例（SP-13 / FR7.2）
    /// SP-13 专用读失败文案（2026-09-16 评审：此前借用 SP-29 同步场景键）。
    /// 拍摄质量标签（Domain QualityTag 键 → 本地化文案；未知键原样回落）
    /// FR7.9 设备自动汇入来源标注（V3.53 §5.45 设备来源行；与自测区分）
    /// SP-13 未连接 Apple 健康空态（§5.45：不渲染设备占位 + 去连接深链）
    // round2 H4（子项目 C7）：SP-13 时间窗分段控件 + 来源过滤（设备项仅本人可见，BR-001）
    /// 四档时间窗标签——switch 静态映射（不拼动态键，静态 t() 键可被 L0 §13 登记判定覆盖）
    /// 诊断性空态（2026-09-16 业主实测）：周期无数据时告知最近读数位置。
    // MARK: - 周期翻页（业主 2026-09-16 第 4 项）
    /// 空周期出口：跳到「最新读数所在周期」（自动锚定周期恒含最近读数）
    /// 首次加载尚未写入身份时的占位标签
    /// 周期标签的 VoiceOver 读法（「当前周期：2026年8月17日 – 8月23日」）
    /// 周期标签本体：日期区间交给平台 `DateIntervalFormatter`（成熟实现优先／
    /// 各语言日期格式与跨年处理不手拼），语言跟随应用内语言（FR14.5 即时切换）。
    // MARK: - 睡眠整合呈现（FR7.11，业主 2026-09-16 第 3 项）
    /// 睡眠整合页标题（六个时长键共乘一页，柱为**一晚**而不是一段）
    /// 阶段图例标题
    /// 阶段名（图例 / 列表 / VoiceOver 共用；switch 静态映射——动态键不在
    /// L0 §13 静态判定覆盖内）
    /// 阶段 + 时长（列表行「深睡 1.2 h」；时长数值经 MedicalNumberFormat 出口）
    /// 空态诊断日期（应用内语言，FR14.5）：与周期标签同一语言出口——
    /// `Date.formatted` 跟随**系统**语言，应用内切换语言后同一屏会出现两种语言。
    /// 逐次构造 formatter（与 trendPeriodRange 同款，不引入跨线程共享的可变 formatter）

    // MARK: - L10n 清偿批五 · 语音速记（SP-59 / FR17.14）
    /// FR2.1 首页扫动处置（业主第10轮 §7）。
    /// FR2.1⑦ 首页按源滑动处置（round2 U-N1/N2/N3）：去药箱 / 稍后（次日重现）/ 查看证据 / 查看 / 操作失败。

    // MARK: - L10n 清偿批五 · 观察（SP-14 / F8）
    // MARK: - 评审批 · F8 观察页与创建页（SP-14 硬编码中文字面量清偿）
    // MARK: - 评审批 · F8 八类观察类型（FR8.1：Domain ObservationKind 枚举 → 名称映射；
    // 未知 key 兜底「其他」本地化串，rawValue 一律不上屏）
    // MARK: - 评审批 · F8.4 敏感媒体（SP-14 步骤2）
    // MARK: - 评审批 · FR8.9/FR17.14 语音速记纯转写入口（共用听写按钮）
    /// 录音按钮的 VoiceOver 提示（业主 2026-09-16 第 5 项：轻点开始/再点结束，也可按住说话）
    /// 未获语音输入权限（与「未识别到语音」区分：原文案把权限拒绝说成没听到声音）
    // MARK: - 评审批 · 文档详情与导出（SP-10 / 5.6）

    // MARK: - L10n 清偿批五 · Pro 产出预览（F23）

    // MARK: - L10n 清偿批五 · 预警与信源（F16）
    // FR16.3 证据卡（V3.68 结构化：Domain 输出类型化数据，本层 L10n 渲染）
    /// 证据卡来源名（复用趋势来源三键，不新增词表）
    // FR16.3/16.4 信源原文详情页

    // MARK: - L10n 清偿批五 · 急救卡（F15）

    // MARK: - L10n 清偿批五 · 疫苗接种（FR4.5 / SP-54）

    // MARK: - L10n 清偿批五 · 通用动作

    // MARK: - L10n 清偿批五 · 双轨库存（FR9.8）

    // MARK: - L10n 清偿批五 · 用药求助卡（FR24.5）
    /// 第七轮修复：求助卡文本组装标签（Domain 注入，生产走三语词表）

    // MARK: - L10n 清偿批五 · AI 助手（F12）
    // ai.history.* / aiHistory.* 键已随 F12 退役删除（会话历史功能下线）


    // MARK: - FR14.8 Tab badge

    // MARK: - §5.10 敏感媒体原始视图

    // MARK: - F22 帮助与诊断（FR22.1-22.4 · SP-42/43/44/45/48）
    /// 第七轮修复：诊断存储大小格式化——「%.1f MB」硬编码单位绕过单出口

    // MARK: - F24 同机照护者视图（FR24.5 · SP-57）

    // MARK: - F20 L2-L4 场景须知（SP-37）

    // MARK: - FR18.6 SOS 全屏求助页（SP-33，唯一免门禁路径）

    // MARK: - F2 首页（SP-04 · FR2.1 八卡）
    /// 📷 单入口标题（FR5.1 V3.61：不前置选类型）
    /// 后台任务（模型下载）首页条目（2026-09-16 业主）：进行中显示，形如档案完善进度卡。
    /// V3.39：原首日引导「了解 AI」行动卡的替代落点（SP-04 空态引导第四任务）

    // MARK: - FR2.1 统一提醒聚合中心（SP-04 · V3.96/V3.97）

    // MARK: - FR14.8 通知中心（SP-27）

    // MARK: - F12 全局搜索（SP-20）
    /// 健康数据搜索组（2026-09-16 委员会评审②）：Apple 健康导入读数可按指标名搜到。

    // MARK: - FR14.5/FR17.15/FR17.16 语言选择器
    /// FR14.5 可显示语言（以该语言原文显示）；en 为 P2 评估项不列
    static var supportedDisplayLanguages: [(code: String, nativeName: String)] {
        [("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文")]
    }

    // MARK: - FR9.5/FR9.17 动作集与时段确认

    // MARK: - FR9.15/FR9.16 计划生命周期与补录（SP-15）
    // FR9.1-9.3 计划创建表单
    /// 第八轮修复：非空但不可解析的剂量文本就地报错（响亮拒绝）

    // MARK: - FR9.9 药品知识卡（§5.40）

    // MARK: - F4 就诊事件（SP-08 · FR4.1-4.4）

    // MARK: - F11 时间轴 + FR11.4 健康问题（SP-19/SP-49）
    // 2026-09-15 审查修复：timelineGradeConfirmed 随 GradeBadge 无障碍改写退役
    // （A/B/C 朗读自身字母+短文案后无读者）——键与三语 .strings 同批删除。

    // MARK: - FR10.4 就诊准备包 / FR10.5 问诊问题

    // MARK: - F10 预约（SP-18 · FR10.1-10.7）
    /// 第七轮修复：FR10.7 错过状态此前无入口（scheduled 行只有改期/取消/完成，
    /// 「错过」过滤段与错过跟进提醒永远空转）

    // MARK: - F3 成员详情/删除/归属确认（FR3.1/3.3/3.4）

    /// 关系显示名单一出口（评审修正）：存储值为中文原始字面量（历史设计），
    /// 显示/无障碍标签必须统一经本映射本地化——此前 Picker、列表行、详情、
    /// 确认条、图标标签各写各的映射，en 界面混排中文。粗细粒度全覆盖。

    // MARK: - F5 资料库（SP-09/SP-10 · FR5.1-5.8 + FR6.6）
    /// 标题显示回落（V3.70 审查）：TimelineProjection 对无题资料输出 ""（数据保真），
    /// 列表/详情/导出/审计/冲突预览等一切显示出口统一经此回落——nil 与空串同义，
    /// 不再让每个消费方各自记住 isEmpty 检查（此前已漏 5 处显示空行）。
    /// 处方副表同步失败的非阻断告警（主文档已保存不回滚，但必须可见）

    // MARK: - 扫描选区 + 文档确认卡（图片入库四角矫正/字段确认）
    // FR6.9 跳过稍后（部分完整卡片 → pending_card 待办，D 级草稿不进事实链）
    // FR6.9 首页聚合中心待办卡
    /// V3.41 文档类型后置判定：确认卡 D 级类型草稿行（可一键改）
    /// FR5.5/FR6.2 类型后置：零命中 → 引导选择；低置信 → 提示核对
    // FR6.9 V3.61 页级实体卡（EntityCardConfirmView / 待办详情多行快照）
    /// 复核清单表头「还有 N 项待复核：日期、类型」（2026-09-17 借鉴批：按风险排序的复核清单，
    /// 取代原先只报必填的计数行）。两处共用：实体卡复核清单、主卡草稿待确认行。
    /// 字段 → 原文行锚定（仅在该字段确有 `sourceLineIndex` 时渲染，绝不用整页原文冒充锚定）。
    /// 歧义项的清单动作：只跳转、不代确认——有候选就必须先做选择（2026-09-17 业主裁定）。

    // MARK: - 共用信息确认步（跨卡字段，业主 2026-09-17 定：确认流程改两步）

    /// 卡类名（data-flow §17.2 card_kind → 展示名；未登记回落原键）
    /// 首页聚合待办卡标题的展示层映射：Domain 投影契约（data-flow §20.1）
    /// 固定为「待补充：{card_kind}」（Domain 零框架无法本地化），此处把
    /// card_kind 映射为本地化卡类名并按当前语言重组前缀；无法解析时原样透传。
    static func pendingCardAggregationTitle(_ title: String) -> String {
        let prefix = "待补充："
        guard title.hasPrefix(prefix) else { return title }
        let kind = String(title.dropFirst(prefix.count))
        return String(format: t("pending.cardTitleFmt"), entityCardKindName(kind))
    }
    // FR17.15 V3.61 主语言（有序多选首位）与尽力识别回显
    // FR17.9 V3.61 双版本（原生转译版 / LLM 修正版，D 级仅作文字清理）
    /// 同日折叠日卡的条数标注（SP-29，业主 2026-09-18 定）
    // 业主 2026-09-17 定：特征型档案候选（D 级候选 → 用户显式确认才写入；不覆盖已有值）
    // 业主 2026-09-17 定：写回 Apple 健康（独立于读取开关的分享授权；关闭只停后续写入）
    // round2 H1/H3/H-N1–N5（子项目 C6）：SP-29 三态文案 / 空态 / 稀疏窗计数 / 回填进度——
    // 全部为统计事实或状态说明，不含任何诊断或阈值判定（BR-003/004）
    /// H-N4：设备不提供 HealthKit（iPad/模拟器）
    /// H-N3：缺本人档案（Apple 健康只能导入到本人名下，BR-001）
    /// H3：系统授权流程未完成（完成≠获准，未完成≠拒绝——读取权限对 App 不可观察）
    /// H-N5：已连接但尚无已导入行的独立空态（不是同步报告语句）
    /// H-N2：<3 样本未形成小时统计的小时桶数
    /// H-N1：回填进度「正在导入 <道>，剩余 N 个统计窗口」（%1 道名 %2 剩余数）
    /// H-N1：回填道名——switch 静态映射（静态 t() 键可被 L0 §13 登记判定覆盖）
    /// 模板字段键 → 展示标签（data-flow §17.2 稳定键；未登记回落原键）
    // 第四轮全仓审查修复：FR6.3 三级置信度/FR6.4 放弃/全部确认闸门/保存失败可见
    // MARK: - 4.28 OCR 信息卡分组（V3.49 · FR17.18 期一）
    /// 信息卡类别标签（Domain FieldGroupRules 类别键 → L10n 单一映射）
    /// 理解层语义字段标签（DocumentTypeClassifierFallback 角色键 → L10n）
    // MARK: - FR11.4 健康问题懒创建（V3.49）
    // MARK: - FR17.19 意图目录确认标签（V3.49 · 九意图动态键，App 映射；D2 退役 F12 后由十减一）
    /// 语音速记面板去 chips 后的提示语（判定由本地理解层自动完成）
    // V3.49 确认卡判定结果行（4.27 可选元素）
    /// 无文字降级提示（Domain ImageInputRules.noTextKey 的 App 层渲染——
    /// Domain 只出类型化键，零硬编码文案）

    // MARK: - 子项目 D · D1-5（v25）：处方行详情 / 就诊叙事分段 / 确认卡「添加字段」/ 处方类型枚举
    /// 多项目处方单折叠标签（业主 2026-09-17 定）
    /// `prescription_type` canonical raw → 展示名（Domain `EntityCardProjection.prescriptionTypes` 同拼写；未登记回落原值）

    // MARK: - 子项目 D · D2-3（v26）：住院 / 诊断 / 检查 / 检验报告读面（SP-08 四分段 + 卡详情）
    /// `diagnosis_type` canonical raw → 展示名（Domain `Diagnosis.diagnosisTypes` 同拼写；未登记回落原值）
    /// `report_type` canonical raw → 展示名（Domain `ExamReport.reportTypes` 同拼写；未登记回落原值）
    /// 检验报告详情：数值项目 / 定性项目分段；标记与结果一律报告原文（BR-004/012 不着色不解释）
    /// 数值/定性分段折叠标签（业主 2026-09-17 定）

    // MARK: - 子项目 D · D4-2「资料建议」表单（SP-12.suggestion.* · §0.3 需求 1 / BR-003）
    /// 「以下内容来自识别结果，尚未核实；仅在您确认后写入资料」
    /// `ProfileSuggestion.Kind.rawValue` → 类别标签（Domain 同拼写；未登记回落原值）
    // BR-003 来源徽章：机器识别未确认（D 级）与显式确认升 C 的入口

    // MARK: - F6 OCR 确认（FR6.3/6.4/6.8 · SP-53）
    /// 第八轮修复：读取点随 W4 批接线前的诚实预告
    /// FR14.7 默认语速（2026-09-11 接线：AVSpeechAdapter rateProvider 消费）
    /// 审查修复：模板为 "余量约 %d%%"——replacingOccurrences 填充后
    /// "%%" 转义永不解除，VoiceOver 念出「余量约 60%%」（双百分号，
    /// 三语同病）。改 String(format:) 由格式器消化 %d 与 %%。
    /// V3.39：队列改为 D 级文档聚合后新增的诚实性说明（BR-003 事实链闸门）

    // MARK: - F23 过敏与不良反应（SP-50 · FR23.1-23.6）
    /// 严重度展示：落库规范值（mild/moderate/severe）先映射回展示词再取文案

    /// 第七轮修复：过敏类型/反应标签词表本地化——表单此前直接渲染 Domain
    /// 中文词表（药品/食物/其他 · 皮疹/荨麻疹/…），en/zh-Hant 用户看到简体；
    /// 与 allergySeverity 同一「词表键」模式

    // MARK: - FR12.10 AI 会话历史 / FR12.8 反馈四键
    // aiHistory.* 键已随 F12 退役删除（会话历史功能下线）

    // MARK: - FR13.1/13.2 PDF 导出向导（SP-22）+ FR13.10 定期备份提醒
    // FR13.2 PDF 封面文案（V3.68：Infrastructure 不拼中文，本层注入）

    // MARK: - FR14.1 九开关 / FR14.7 偏好中心 / FR14.3 数据生命周期

    // MARK: - FR21.9 向导 ④ 添加家人（⑥ 首日引导 V3.39 起由首页空态引导卡承载，不再占用向导步骤）
    /// V3.39：新增成员后向导最后一步的主按钮文案（跳过与完成语义分离）

    // MARK: - FR22.5 反馈 / FR24.2 发送状态 / FR9.13a 收件人

    // MARK: - FR7.5 自测两步录入（SP-13 快速录入）
    // FR7.5 录入失败可见反馈（解析失败/写失败——绝不静默丢弃读数）
    /// 手录指标超出合理性界限（MetricEntryRules 拒绝落库时的可见反馈）

    // MARK: - FR17.9 语音速记面板（SP-55）+ FR8.10 观察随访
    // FR8.11 观察详情页（SP-14 §5.7.1）
    /// 删除失败告警（响亮失败：deleteObservation 返回 false 必须有可见错误面）

    // MARK: - F16 设备接入（SP-29/SP-30）
    // 既有 API 名保留；连接完成与读取授权不可等同，HealthKit 不透露读取权限。
    /// 本次成功安排的通知数，不是已送达数或预警事件数。
    /// FR7.9 指标投影变更数，包含新增、更新与移除。
    /// V3.86 FR16.1 V3.49 同步时间沟通契约
    // FR16.4「范围不可用」独立呈现态（无信源阈值的读数计数）
    /// 设备与信源沿用既有指标键映射；未知 raw key 不上屏。

    // MARK: - F19 附表执行矩阵播报（纯事实句式）
    /// 第七轮修复：会话内导航指令回落提示（原「打开时间轴/回到首页」硬编码中文字面量）
    /// §5.48 已删除实体降级（第七轮修复）：目标实体已删除/跨成员 → 提示并自弹回根
    /// 启动降级分型（2026-09-16 评审）：稳定文案替代直插英文诊断。
    /// 第八轮修复：文法命中数值但 ≤0（如「血糖零」）——响亮拒绝，绝不静默丢弃
    /// F19 附表①清单分页：列选项（「下一页」）+ 剩余条数播报

    // MARK: - FR15.2 系统医疗急救卡引导

    // MARK: - FR17.15 V3.66 识别引擎实验室（SP-62）
    /// 复审修正 FIX-B：对照测试的回落诚实标注（资源未装 / 系统不支持）。
    /// 审计修正（round3）：缺件随包模型的回落标注。
    /// 旧键保留：运行时下载模型与随包基线共用「安装后离线」文案。
    /// FR17.15（业主 2026-09-12）：运行时模型下载 UI。
    /// 模型尺寸选择（业主 2026-09-18 定：目录含同 id 多档时出现）
    /// 变体档位名：登记 small/medium/large 三档本地化，未登记键回落原文
    /// 业主裁决 D6：设备 RAM 建议提示（参数1=建议档位名，参数2=设备 RAM GB）
    /// 检查更新三元反馈（2026-09-16 业主实测：此前点击后无任何可见结果）。
    /// 下载进度（字节数双参——慢链路下进度条位移缓慢，数字给确定反馈）。
    /// 传输形态（2026-09-16 业主实测「ASR 下载速度很慢」）：`supportsRanges` 为假、
    /// 或 HEAD 最终响应不带 `Accept-Ranges: bytes` 时下载会**静默退化**为单流——
    /// 1 条连接 vs 分段 N 路并发。此前无任何出口可判定，只能猜；呈现出来即可当场分辨。
    /// 安装阶段文案（下载后的校验/解压/安装/清理此前完全无反馈）。

    // MARK: - FR6.9 V3.66 一键确认与卡片互联

    enum TargetTag: String, CaseIterable {
        case metric, observation, question, reminder, profile, anyText
    }

    /// 支持的本地化（三文件纪律）
    static let supportedLocalizations = ["zh-Hans", "zh-Hant", "en"]

    // MARK: - FR14.5 语言即时切换（无需重启）
    //
    // 直接按选定语言从对应 .lproj 解析——NSLocalizedString 跟随系统语言且
    // 每进程缓存，无法满足「切换即时生效、不要求重启」（FR14.5 验收）。
    // 视图层全部经本单出口取值：语言变更 → AppSettingsStore.values 变化 →
    // 视图重渲染 → t() 按新语言解析。

    /// 当前显示语言（"zh-Hans"/"zh-Hant"）。nonisolated(unsafe)：
    /// 写只发生在 App 启动与语言设置变更（主线程 UI 流程）。
    /// 审查修复（V3.70）：PDF 导出的 @Sendable 文案闭包使 t() 从
    /// Infrastructure actor 后台执行器并发可达——无锁读写语言/包缓存存在
    /// 撕裂风险（导出中途切语言 → 半新半旧文案或裸 key 上 PDF）。
    /// 缓存读写统一加锁，读路径成本可忽略（锁内仅字典/指针级操作）。
    nonisolated(unsafe) private static var languageCache: String = "zh-Hans"
    nonisolated(unsafe) private static var bundleCache: Bundle?
    private static let cacheLock = NSLock()

    static var bundleLanguage: String {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return languageCache
    }

    // MARK: - 评审批新增键（2026-09-06 全仓审查）
    // assistantSendLabel 已随 F12 退役删除（assistant.* 键清零）

    /// 语言切换通知：setLanguage 仅在语言真正变化时发送。
    /// 视图重渲染由 AppSettingsStore.values[.language] 的 @Observable 读值驱动
    /// （AppRootView body 读取），本通知仅作非视图副作用信号
    /// （ReminderStore 重写待投递通知的本地化文案）。
    static let languageDidChange = Notification.Name("L10nLanguageDidChange")

    /// FR14.5 语言切换入口（设置页调用；App 启动时以持久化偏好初始化）。
    /// 相等性守卫（评审修正）：同值重复设置不得再发通知——此前每次启动
    /// 的 .task 都会以「已存储语言」再设一遍并广播，触发整树重建/重启循环。
    static func setLanguage(_ lang: String) {
        guard supportedLocalizations.contains(lang) else { return }
        cacheLock.lock()
        let changed = languageCache != lang
        if changed {
            languageCache = lang
            bundleCache = nil
        }
        cacheLock.unlock()
        UserDefaults.standard.set(lang, forKey: "vl.language")
        if changed {
            NotificationCenter.default.post(name: languageDidChange, object: lang)
        }
    }

    /// 启动恢复：从持久化偏好初始化（VitaLiberApp.init 同步调用——
    /// 首帧渲染前语言已就位，消除非默认语言用户的启动语言闪烁）。
    /// 只恢复不发通知：视图重渲染由 AppSettingsStore.values[.language]
    /// 的 @Observable 读值驱动（见本文件语言机制注释）。
    static func restoreLanguage() {
        let stored = UserDefaults.standard.string(forKey: "vl.language") ?? "zh-Hans"
        guard supportedLocalizations.contains(stored) else { return }
        cacheLock.lock()
        languageCache = stored
        bundleCache = nil
        cacheLock.unlock()
    }

    // MARK: - 子项目 J · J4（v27 card-hierarchy）：时间轴主卡折叠 / 主卡草稿 / 体检详情 / 四卡类 / 文档稳定键

    /// SP-19 主卡行「详情」按钮（DisclosureGroup 标签区内的独立触点，≥44pt）。
    /// 计数徽章 VoiceOver 文案：「处方 1」（%1 类型名 %2 数量）。
    /// 处方子卡摘要（store 以行数文本承载 summary，App 侧格式化「N 项」）。
    /// 结论聚合子卡标题（store 以条数文本承载 title）。

    /// `conclusion_type` canonical raw → 类型名（Domain `ClinicalConclusion.conclusionTypes` 同拼写；未登记回落原值）。
    /// 只映射类型名；`severity_text` 是打印原文，永不经此映射、不着色（BR-004/012）。
    /// `treatment_type` canonical raw → 展示名（Domain `TreatmentRecord.treatmentTypes` 同拼写；未登记回落原值）。
    /// `appointment.purpose` canonical raw → 展示名（Domain `AppointmentPurpose` 同拼写；未登记回落原值）。
    /// FR5.5 文档类型稳定键 → 三语标签（`DocumentTypeKey.rawValue` 同拼写；未登记回落原键）。

    /// 标签 → 稳定键 rawValue：当前语言 27 键精确 → 旧标签键三语反查 → `DocumentTypeKey(legacyLabelKey:)`；未命中 nil。
    /// 结果按（语言, 标签）缓存（锁保护；语言切换后键前缀不同、自然失效）。
    static func docTypeKey(forLabel label: String) -> String? {
        let cacheKey = bundleLanguage + "|" + label
        cacheLock.lock()
        if let hit = docTypeKeyCache[cacheKey] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let resolved: String?
        if let exact = DocumentTypeKey.allCases.first(where: { docTypeName($0) == label }) {
            resolved = exact.rawValue
        } else if let legacy = legacyDocTypeLabelKey(forLabel: label) {
            resolved = DocumentTypeKey(legacyLabelKey: legacy)?.rawValue
        } else {
            resolved = nil
        }
        cacheLock.lock()
        docTypeKeyCache[cacheKey] = resolved
        cacheLock.unlock()
        return resolved
    }
    nonisolated(unsafe) private static var docTypeKeyCache: [String: String?] = [:]

    /// 旧 `document_file.doc_type` 标签（任一支持语言的历史文案）→ 旧标签键（`docTypeLabel.*` 15 键 / `doc.type.*` /
    /// `claim.type.invoice` 等曾作为文档类型标签写库的键）。首启回填经 `DocumentTypeKey(legacyLabelKey:)` 落稳定键；未命中 nil。
    /// 跨三语反查：老库可能是在另一语言下写入的标签。

    /// SP-12 主卡草稿区（§0.4 改判：识别出的子卡永远有父；草稿 D 级、逐字段确认，BR-003）。

    /// 体检详情（`AppRoute.healthExamDetail`）：表头 → 一般检查原文 → 子报告 → 结论（原文，不着色）→ 原件。
    /// 检测检查项折叠标签（业主 2026-09-17 定）

    /// SP-08 四新分段 + 「关联预约」（FR10.7：候选只是清单，挂接须用户显式确认，不自动生效）。

    /// 指定语言的资源包（不写缓存；供跨语言反查）。查找链与 `currentBundle` 同构
    /// （共用同一 `resolveBundle(forLanguage:)` 实现——原两条同构链各自复制四步
    /// 回落，增补一步回落必须改两处且极易漏一处）。
    static func bundle(forLanguage lang: String) -> Bundle? {
        resolveBundle(forLanguage: lang)
    }

    /// 四步回落查找链：Bundle 根 .lproj（标准打包路径）→ Resources/Localization/
    /// 子目录（XcodeGen 源码树保留路径）→ Localizable.strings 父目录 → 全量
    /// .lproj 扫描。失败返回 nil（由调用侧决定缓存与否）。
    /// 注：`paths(forResourcesOfType:inDirectory:)` 返回 [String]（非 Optional），
    /// 空数组由 for 循环自然空转——if let 绑定非 Optional 是类型错误
    /// （CI 34019956499 实证：此回落链此前从未通过真实编译）。
    private static func resolveBundle(forLanguage lang: String) -> Bundle? {
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"), let bundle = Bundle(path: path) { return bundle }
        if let url = Bundle.main.url(forResource: lang, withExtension: "lproj", subdirectory: "Resources/Localization"),
           let bundle = Bundle(url: url) { return bundle }
        if let stringsURL = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(lang).lproj"),
           let bundle = Bundle(url: stringsURL.deletingLastPathComponent()) { return bundle }
        for p in Bundle.main.paths(forResourcesOfType: "lproj", inDirectory: nil) {
            let name = URL(fileURLWithPath: p).lastPathComponent
            if name == "\(lang).lproj" || name == lang, let bundle = Bundle(path: p) { return bundle }
        }
        return nil
    }

    static func t(_ key: String) -> String {
        if let bundle = currentBundle {
            let value = bundle.localizedString(forKey: key, value: key, table: nil)
            if value != key { return value }   // 缺译回落系统默认（三文件纪律由 SU-M15-L10N 兜底）
        }
        return NSLocalizedString(key, comment: "")
    }

    static var currentBundle: Bundle? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = bundleCache { return cached }
        if let bundle = resolveBundle(forLanguage: languageCache) {
            bundleCache = bundle
        }
        return bundleCache
    }
}
