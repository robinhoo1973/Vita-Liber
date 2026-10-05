import SwiftUI
import Domain
import Infrastructure
import Perception

/// FR17.15 生产设置：选择直接写入 voiceEngine，下一次按压从同一键解析。
/// 业主 2026-09-12 决定：随包模型之外新增**运行时下载路径**——
/// 本区块负责「检查更新 / 下载 / 更新 + 进度 + 失败可重试」；识别会话路径绝不联网。
///
/// 2026-09-16 业主实测修复批（语音下载体验）：
/// - **阶段进度**：下载后的校验/解压/安装/清理此前完全无反馈（用户判定「卡死」）——
///   接入 `InstallPhase`，下载显示分数进度 + 字节数字（慢链路下条位移缓慢，数字给确定反馈），
///   后续阶段显示不确定进度 + 阶段文案；
/// - **多任务**：此前单 `busy` 全局互斥，第二个下载被静默拒绝——改 per-choice 进行态集合
///   （服务端已按 per-model 互斥 + 并发上限 2）；
/// - **切后台**：iOS 26 continued processing 续跑；更早系统 `beginBackgroundTask` 仅 ≈30 秒（非 30 分钟），文案按版本如实更新；
/// - **检查更新三元反馈**：检查中 / 已是最新 / 发现 N 个可更新 / 失败（此前点击无任何结果）；
/// - **资产失效广播**：安装成功 `assetsChanged()`——语言列表据此重算可选性
///   （此前同页内下载完成不触发重算，「下载完了还是不能选」）。
struct ASREngineSettingsSection: View {
    @Environment(AppSettingsStore.self) private var settings
    /// 安装中心（App 层，2026-09-16 提升）：进行态在此**全局可见**（首页同源），
    /// 离开设置页不再丢失；本页只自持索引与检查状态。
    @Environment(ASRInstallCenter.self) private var installCenter
    /// 必填（2026-09-28 评审修复：默认 "SP-25" 已成死参数——唯一挂载点在统一
    /// 资源页；漏传前缀会造成 a11y id 撞 SP-25 族）。
    var accessibilityPrefix: String
    @Environment(AppState.self) private var app
    /// 关怀模式触点（2026-10-05 委员会 R4）：本区块动作按钮此前固定 44pt,
    /// 关怀 64pt 纪律未落地——统一走 CareModeMetrics(与药箱行/PagingStepper 同源)。
    private var metrics: CareModeMetrics { app.careMode ? .care : .standard }

    /// 「检查更新」三元结果（业主实测：此前点击无任何可见反馈）。
    private enum IndexCheckState: Equatable {
        case idle, checking, upToDate, updates(Int), failed
    }

    @State private var index: ASRModelReleaseIndex?
    @State private var checkState: IndexCheckState = .idle
    /// 破坏性/高成本动作确认载荷（2026-10-05 委员会）：删除家族 / 换档切换
    /// （单保留语义 = 删旧档 + GB 级下载，条件确认仅对替换已装档时弹）。
    private enum PendingConfirm: Identifiable {
        case delete(VoiceEngineChoice)
        case switchTier(VoiceEngineChoice, ASRModelRelease)

        var id: String {
            switch self {
            case .delete(let choice): return "delete-\(choice.rawValue)"
            case .switchTier(let choice, let release): return "switch-\(choice.rawValue)-\(release.sha256)"
            }
        }
        var title: String {
            switch self {
            case .delete: return L10n.asrModelDeleteTitle
            case .switchTier: return L10n.asrModelSwitchConfirmTitle
            }
        }
        var confirmLabel: String {
            switch self {
            case .delete: return L10n.asrModelDeleteConfirm
            case .switchTier: return L10n.asrModelSwitchConfirmAction
            }
        }
        var message: String {
            switch self {
            case .delete:
                return L10n.asrModelDeleteMessage
            case .switchTier(_, let chosen):
                let tier = chosen.tierName?.resolved() ?? L10n.asrModelVariantName(chosen.variant ?? "")
                let size = L10n.asrModelBytes(chosen.bytes ?? 0)
                return L10n.asrModelSwitchConfirmMessage(tier, size, tier)
            }
        }
    }
    @State private var pendingConfirm: PendingConfirm?
    /// 删除失败提示（如实呈现，可重试）。
    @State private var deleteFailed: Set<String> = []

    /// 每档位的派生结论（已装版本 / 最新发布 / 可更新目标）。
    ///
    /// **不在 `body` 里算**——业主 2026-09-16 实测「进入本页、或模型已下载时，
    /// 闪退或死机」。机制：这些判定都要取 `ModelCatalogTrustStore.shared`，而它是
    /// **锁保护的非 actor 类**（`NSLock` + 缓存），且「检查更新」经 `fetchIndex` 在
    /// actor 上**持同一把锁做信任根/目录的签名验签**。渲染路径每帧从这把锁取值，
    /// 验签期间主线程就在锁上排队 → 界面冻结 → 看门狗强杀（表现为闪退）。
    /// 模型已下载时渲染路径更多一轮 `isRevoked`/`installedVersion`，锁竞争更重，
    /// 这正是「已下载才发作」的来源。每次重绘还会重复整套判定。
    ///
    /// 改为 `.task` 一次算好存 `@State`，body 只读结果：渲染路径不再触碰那把锁。
    /// （更彻底的做法是把信任库改为 actor / 拆出只读快照，已登记为后续项——
    /// 那会改动 CoreKit 的公开面，不宜与本次修复混批。）
    private struct ChoiceAvailability: Sendable {
        var installed: String?
        var latest: ASRModelRelease?
        var update: ASRModelRelease?
        /// 引擎可用性判定（`TranscriptionEngineBuilder.availability`）——同样要读
        /// 信任库/资产目录，故一并移出渲染路径
        var availability: VoiceEngineAvailability = .available
        /// 该档位的资产字节数（`ASRModelAssets.byteCount`：读 manifest + 逐文件 stat
        /// + `isRevoked` 取锁），渲染路径只读结果
        var bytes: Int64?
        /// 已激活指针的档位键（2026-09-19 审查修复：同版本换档判定输入）。
        var installedVariant: String?
        /// 该档位在索引中的变体清单（小/中/大，业主 2026-09-18 定）：同 id 多条目
        /// 且带 variant 键；单档/历史条目为空（UI 保持旧形态）。在重算预算内
        /// 一并算出——渲染路径不得再取锁。
        var variants: [ASRModelRelease] = []
        /// 许可文案（2026-10-05 目录驱动：取自目录条目，App 不再内置模型数据表）。
        var license: String?
    }
    @State private var availability: [String: ChoiceAvailability] = [:]
    /// 目录家族清单（2026-10-05 业主定：下载列表由签名索引**自动生成**，App 不写死
    /// 家族清单——`VoiceEngineChoice` 引擎支持集合只是渲染上限，行集/行序随目录）。
    @State private var catalogFamilies: [VoiceEngineChoice] = []
    /// 目录文案（家族名/简介，2026-10-05 业主定：模型文字描述由 CI 生成的目录 JSON
    /// 提供；旧目录缺字段时回落到内置 L10n 兜底）。
    @State private var familyNames: [String: String] = [:]
    @State private var familyHints: [String: String] = [:]
    /// 派生结论的重算触发：索引拉取成功 + 安装态变化（开始/结束）时自增。
    @State private var derivationEpoch = 0
    /// 尺寸选择记忆（choice → variant 键；默认取清单首个=最小档）
    @State private var selectedVariant: [String: String] = [:]

    private let service = ASRModelDownloadService.shared

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    /// 派生结论的重算键：索引代次 + 进行中安装的档位集合（开始/结束都要重算按钮形态）。
    private var derivationKey: String {
        let active = installCenter.active.map(\.choice.rawValue).sorted().joined(separator: ",")
        return "\(derivationEpoch)|\(active)"
    }

    /// 一次算好全部 bundled 档位的派生结论。
    /// 审查修复（主线程阻塞加固，2026-09-18）：派生结论此前直接在主 actor 上
    /// 计算——每档位数次取 ModelCatalogTrustStore 的锁 + 读盘；「检查更新」
    /// 的火忘任务（可能来自上一次页面访问）持锁验签/落盘期间主线程排队 →
    /// 冻结 → 看门狗强杀（业主实测「下载失败后再次进入页面闪退/死机」）。
    /// 锁持有时长已在上游修复（acceptCatalog/acceptRoot 锁外验签落盘）；
    /// 本侧再把全部取锁/读盘计算移出主 actor（detached），结果一次 hop 回填。
    private func rebuildAvailability() async {
        let pageIndex = index
        let version = appVersion
        let preferred = Locale.preferredLanguages
        let computed = await Task.detached(priority: .userInitiated) { () -> ([String: ChoiceAvailability], [VoiceEngineChoice], [String: String], [String: String]) in
            let availableIndex = pageIndex
                ?? ModelCatalogTrustStore.shared.currentIndex
                ?? ModelCatalogTrustStore.shared.baselineIndex
            var next: [String: ChoiceAvailability] = [:]
            for choice in VoiceEngineChoice.allCases {
                next[choice.rawValue] = ChoiceAvailability(
                    installed: choice.isBundledModel ? ASRModelDownloadService.installedVersion(for: choice) : nil,
                    latest: choice.isBundledModel ? availableIndex.flatMap {
                        ASRModelDownloadService.latest(for: choice, in: $0, appVersion: version)
                    } : nil,
                    update: choice.isBundledModel ? availableIndex.flatMap {
                        ASRModelDownloadService.updateAvailable(for: choice, index: $0, appVersion: version)
                    } : nil,
                    availability: TranscriptionEngineBuilder.availability(of: choice),
                    // 资产字节数只对随包档位展示（`isBundledModel` 同款条件）
                    bytes: choice.isBundledModel
                        ? ASRModelAssets.resolve(for: choice).byteCount(choice)
                        : nil,
                    installedVariant: choice.isBundledModel ? ASRModelDownloadService.installedVariant(for: choice) : nil,
                    // 变体清单（尺寸选择数据源）：同 id 已发布、带 variant、本版本兼容
                    variants: availableIndex.map { idx in
                        idx.models
                            .filter { $0.id == choice.rawValue && $0.isPublished && $0.variant != nil && $0.isCompatible(appVersion: version) }
                            // 审查修正（D6 档序颠倒）：字典序 "large" < "medium" < "small"
                            // 与大小序相反——此前清单首位是大档（默认选中大档、低 RAM
                            // 设备被推荐大档）。统一按 Domain variantWeight 大小升序。
                            .sorted { ASRModelRelease.variantWeight($0.variant) < ASRModelRelease.variantWeight($1.variant) }
                    } ?? [],
                    // 许可文案取自目录条目（2026-10-05 目录驱动：App 零模型数据硬编码）
                    license: availableIndex?.models.first {
                        $0.id == choice.rawValue && $0.isPublished && $0.isCompatible(appVersion: version)
                    }?.license)
            }
            // 目录家族清单：按索引发布序去重，只保留本 App 引擎可运行的家族
            // （rawValue 可解析且属于随包模型档）；未知 id = 新目录对旧 App，跳过。
            var seen = Set<String>()
            var families: [VoiceEngineChoice] = []
            for release in availableIndex?.models ?? [] where !seen.contains(release.id) {
                seen.insert(release.id)
                if let choice = VoiceEngineChoice(rawValue: release.id), choice.isBundledModel {
                    families.append(choice)
                }
            }
            var names: [String: String] = [:]
            var hints: [String: String] = [:]
            for family in availableIndex?.families ?? [] {
                if let value = family.name?.resolved(preferredLanguages: preferred) { names[family.id] = value }
                if let value = family.hint?.resolved(preferredLanguages: preferred) { hints[family.id] = value }
            }
            return (next, families, names, hints)
        }.value
        availability = computed.0
        catalogFamilies = computed.1
        familyNames = computed.2
        familyHints = computed.3
    }

    var body: some View {
        WithPerceptionTracking {
            Section {
                // 安全审查 2026-09-12：索引拉取改为「检查更新」显式按钮触发——
                // 此前区块出现即自动 GET（reloadIgnoringLocalCacheData）属契约外
                // 隐式联网面（零隐式联网红线的唯一例外必须显式发起）。
                Button {
                    // 单飞守卫（审查修复）：连点/返回再点不再叠第二个拉取任务
                    guard refreshTask == nil else { return }
                    refreshTask = Task { await refreshIndex() }
                } label: {
                    HStack {
                        Label(L10n.asrModelCheckUpdate, systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if checkState == .checking { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity, minHeight: metrics.touchTarget)
                }
                .buttonStyle(.bordered)
                // 下载中禁用（tech-spec §5.29「区块顶部 [检查更新] 按钮（…≥44pt、下载中禁用）」）：
                // 服务层 `fetchIndex` 在 `installing` 非空时抛 `installInProgress`，
                // 而 UI 把该错误一律渲染为「检查更新失败，请重试」——用户会把
                // 「正在下载」误读成「功能坏了」（2026-09-16 评审）。
                .disabled(checkState == .checking || !installCenter.active.isEmpty)
                .accessibilityIdentifier("\(accessibilityPrefix).model.checkUpdate")

                // 检查结果三元反馈（进行中由按钮内 spinner 承担）
                switch checkState {
                case .upToDate:
                    Text(L10n.asrModelCheckUpToDate)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.checkUpToDate")
                case .updates(let count):
                    Text(L10n.asrModelCheckUpdates(count))
                        .font(.caption).foregroundStyle(Color("brand-primary", bundle: .main))
                        .accessibilityIdentifier("\(accessibilityPrefix).model.checkUpdates")
                case .failed:
                    Text(L10n.asrIndexFetchFailed)
                        .font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
                        .accessibilityIdentifier("\(accessibilityPrefix).model.indexFailed")
                case .idle, .checking:
                    EmptyView()
                }

                // 平台档（本地引擎轨，非目录内容）固定呈现；模型家族行由签名索引
                // 自动生成（2026-10-05 业主定：下载列表不写死，目录有哪家就列哪家）。
                ForEach([VoiceEngineChoice.auto], id: \.self) { engineRow($0) }
                ForEach(catalogFamilies, id: \.self) { engineRow($0) }
                ForEach([VoiceEngineChoice.advanced, .dictation, .classic], id: \.self) { engineRow($0) }
            } header: { Text(L10n.voiceLabEngineSection) }
              footer: { Text(L10n.asrSelectionHint) }
              // 2026-10-05 删除确认（第 6 项）：删除释放空间，语音识别回落到随包模型
              // （如有）或需重新下载——确认是显式动作（防误删 GB 级资产）。
              .confirmationDialog(pendingConfirm?.title ?? "",
                                  isPresented: Binding(get: { pendingConfirm != nil },
                                                       set: { if !$0 { pendingConfirm = nil } }),
                                  titleVisibility: .visible) {
                Button(pendingConfirm?.confirmLabel ?? "", role: .destructive) {
                    switch pendingConfirm {
                    case .delete(let choice): deleteModel(choice)
                    case .switchTier(let choice, let release): startInstall(release)
                    case nil: break
                    }
                    pendingConfirm = nil
                }
                Button(L10n.commonCancel, role: .cancel) { pendingConfirm = nil }
              } message: {
                Text(pendingConfirm?.message ?? "")
              }
            // 派生结论在渲染路径之外算（见 `availability` 的说明）。
              // **必须挂在追踪闭包内**：`derivationKey` 读 `installCenter.active`，
              // 挂到闭包外则读值不被追踪，安装开始/结束时 id 不变、任务不重跑，
              // 按钮形态会停在旧态。
              .task(id: derivationKey) { await rebuildAvailability() }
              .onDisappear { refreshTask?.cancel() }
        }
    }

    /// 引擎行（平台档与目录家族共用同一形态）。家族名/简介优先取目录 JSON 文案
    /// （2026-10-05 业主定：文字描述由 CI 目录提供），旧目录缺字段回落到内置 L10n。
    @ViewBuilder
    private func engineRow(_ choice: VoiceEngineChoice) -> some View {
        // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
        WithPerceptionTracking {
            // 可用性与字节数只读 `.task` 预算好的结果——它们是本页最重的
            // 两次取锁/读盘（`TranscriptionEngineBuilder.availability` 读信任库、
            // `ASRModelAssets.byteCount` 读 manifest + 逐文件 stat），
            // 此前每帧、每档位各来一次（见 `availability` 的说明）
            let row = availability[choice.rawValue] ?? ChoiceAvailability()
            Button {
                Task { await settings.set(choice.rawValue, for: .voiceEngine) }
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(familyNames[choice.rawValue] ?? L10n.voiceEngineName(choice))
                        Text(familyHints[choice.rawValue] ?? L10n.voiceEngineHint(choice))
                            .font(.caption).foregroundStyle(.secondary)
                        if choice.isBundledModel {
                            if let license = row.license {
                                Text(license + " · " + L10n.asrBundledOffline)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let bytes = row.bytes {
                                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let note = L10n.asrAvailability(row.availability) {
                            Text(note).font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
                        }
                    }
                    Spacer()
                    if VoiceEngineChoice.resolve(settings.values[.voiceEngine]) == choice {
                        // T3 呈现评审：选中标记收敛为纯 checkmark（与此前语言页/
                        // 实验室三处同形态；checkmark.circle.fill 为唯一异形）
                        Image(systemName: "checkmark").foregroundStyle(Color("brand-primary", bundle: .main))
                    }
                }.frame(minHeight: metrics.touchTarget)
            }
            .buttonStyle(PressScaleButtonStyle())   // 按压反馈统一（§3.3 V4.05）
            .accessibilityIdentifier("\(accessibilityPrefix).engine.\(choice.rawValue)")

            if choice.isBundledModel {
                downloadControls(choice)
            }
        }
    }

    // MARK: - 运行时下载（FR17.15 业主 2026-09-12 决定）

    @ViewBuilder
    private func downloadControls(_ choice: VoiceEngineChoice) -> some View {
        // 只读 `.task` 预算好的派生结论——渲染路径不再触碰 `ModelCatalogTrustStore`
        // 的那把锁（见 `availability` 的说明）。
        let row = availability[choice.rawValue] ?? ChoiceAvailability()
        let installed = row.installed
        let latest = row.latest
        let update = row.update
        let variants = row.variants
        // 尺寸选择（业主 2026-09-18 定）：目录含同 id 多档（small/medium/large）
        // 时出现分段选择器；单档/历史目录保持旧形态（无选择器）。
        let chosenVariant: ASRModelRelease? = variants.count > 1
            ? (variants.first { $0.variant == selectedVariant[choice.rawValue] } ?? variants.first)
            : nil
        VStack(alignment: .leading, spacing: 4) {
            if let installed {
                // 已装行如实显示生效档位(2026-10-05 委员会):多档共存时「已安装 vX」
                // 不足以让用户知道 active 是哪一档——档位名优先取目录 JSON 文案,
                // 旧目录回落到既有 L10n 键(零新增文案面)。
                HStack(spacing: 4) {
                    Text(L10n.asrModelInstalled(installed))
                    if let installedVariant = row.installedVariant {
                        Text(tierDisplayName(installedVariant, variants: variants))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(accessibilityPrefix).model.installed.\(choice.rawValue)")
            }
            if !variants.isEmpty {
                if variants.count > 1 {
                    Picker(L10n.asrModelVariantTitle, selection: variantBinding(choice, variants, installedVariant: row.installedVariant)) {
                        ForEach(variants) { v in
                            Text(tierDisplayName(v.variant, variants: variants)).tag(v.variant ?? "")
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("\(accessibilityPrefix).model.variant.\(choice.rawValue)")
                }
                if variants.count > 1 {
                    // 系统推荐（2026-10-05 第 9 项）：推荐 = 内存预算可装的最大档
                    // （与 auto 档「完整解码模型优先」同语义），探针不可用回落
                    // RAM 档位建议（D6）→ 最小档。只对多档家族显示——单档家族
                    // 「建议选择」是空命题（无选择控件），且制造不存在的档位期待
                    // （2026-10-05 委员会：qwen3 单档标 medium 时文案直出「中」）。
                    if let hint = variantHint(for: variants) {
                        Text(hint)
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("\(accessibilityPrefix).model.variantHint.\(choice.rawValue)")
                    }
                } else if !variants.isEmpty {
                    // 单档家族「仅一档」徽标：如实缺省的呈现面（缺档不虚构）。
                    Text(L10n.asrModelSingleTier)
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.singleTier.\(choice.rawValue)")
                }
                // 每档参数说明(业主 2026-10-05):档位性能/专长文案由目录 JSON 提供
                // (CI 生成,App 只渲染);参数行列出所选档的下载/解压体积与内存需求
                // (Domain 峰值口径)——只给可核实参数,不定义大/中/小。
                if let detailVariant = variants.count > 1 ? chosenVariant : variants.first {
                    if let hint = detailVariant.tierHint?.resolved() {
                        Text(hint)
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("\(accessibilityPrefix).model.tierHint.\(choice.rawValue)")
                    }
                    Text(L10n.asrModelVariantDetail(
                        L10n.asrModelBytes(detailVariant.bytes ?? 0),
                        L10n.asrModelBytes(detailVariant.expandedBytes ?? 0),
                        L10n.asrModelBytes(ModelMemoryBudget.peakBytes(modelBytes: detailVariant.expandedBytes ?? 0))))
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.variantDetail.\(choice.rawValue)")
                }
                // 单档且内存预算不可载：如实预警并禁用下载（防「下载完不可用」——
                // 预算门在按压时还会拒绝加载，先下载只是浪费 GB 级流量与空间）。
                if let warning = memoryWarning(for: variants) {
                    Text(warning)
                        .font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
                        .accessibilityIdentifier("\(accessibilityPrefix).model.memoryWarning.\(choice.rawValue)")
                }
            }
            if let active = installCenter.install(choice) {
                installProgress(choice, active)
            } else {
                if installCenter.failed.contains(choice) {
                    // 失败提示与重试按钮并存：此前失败态被更新/下载按钮分支
                    // 永远遮蔽（分支顺序 bug），下载失败完全无反馈。
                    Text(L10n.asrModelDownloadFailed)
                        .font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
                        .accessibilityIdentifier("\(accessibilityPrefix).model.failed.\(choice.rawValue)")
                }
                if let chosenVariant {
                    // 多档家族：下载/更新以所选档为目标（各档可共存下载、同一时刻
                    // 一档生效——ASRInstallLayout 语义；已装版本不提示重复下载）。
                    // 2026-09-19 审查修复：此前仅按版本判定——同版本换档（small→large）
                    // 恒无下载按钮（isNewer 只比版本号），尺寸选择形同虚设。
                    // 判定是 BR 业务规则——2026-09-19 上移 Domain（CLAUDE.md 规则 4：
                    // 业务判定不得留在 View 内），视图只读结果。
                    let needsInstall = chosenVariant.needsInstall(
                        installedVersion: installed,
                        installedVariant: row.installedVariant)
                    if needsInstall {
                        // 按钮标签三分支(2026-10-05 委员会):未装=「下载 X 档(体积)」/
                        // 同档新版本=「更新到 vX」/ 换档=「切换到 X 档(体积)」+ 条件确认
                        // (仅替换已装档时弹;纯新装/同档更新不弹——HIG 破坏性确认,
                        // 单保留裁定封死了 undo,确认是缺失 undo 的补偿控制)。
                        // 档位名优先目录 JSON 文案,旧目录回落 L10n 映射。
                        let tierName = tierDisplayName(chosenVariant.variant, variants: variants)
                        let tierSize = L10n.asrModelBytes(chosenVariant.bytes ?? 0)
                        if installed == nil {
                            Button(L10n.asrModelDownloadTier(tierName, tierSize)) { startInstall(chosenVariant) }
                                .buttonStyle(.bordered).frame(minHeight: metrics.touchTarget)
                                .disabled(memoryWarning(for: variants) != nil)
                                .accessibilityIdentifier("\(accessibilityPrefix).model.variantInstall.\(choice.rawValue)")
                        } else if chosenVariant.variant == row.installedVariant {
                            Button(L10n.asrModelUpdate(chosenVariant.version)) { startInstall(chosenVariant) }
                                .buttonStyle(.bordered).frame(minHeight: metrics.touchTarget)
                                .accessibilityIdentifier("\(accessibilityPrefix).model.variantInstall.\(choice.rawValue)")
                        } else {
                            Button(L10n.asrModelSwitchTier(tierName, tierSize)) {
                                pendingConfirm = .switchTier(choice, chosenVariant)
                            }
                                .buttonStyle(.bordered).frame(minHeight: metrics.touchTarget)
                                .accessibilityIdentifier("\(accessibilityPrefix).model.variantInstall.\(choice.rawValue)")
                            // 切换成本预教育(2026-10-05 委员会):旧档将被删除,切回需重下
                            // (业主 2026-10-05 裁定「每家族最多保留一个已装档」)。
                            Text(L10n.asrModelVariantReplaces)
                                .font(.caption2).foregroundStyle(.secondary)
                                .accessibilityIdentifier("\(accessibilityPrefix).model.variantReplaces.\(choice.rawValue)")
                        }
                        // R3(2026-10-05 委员会):多档家族按所选档内存预警——只预警
                        // 不禁用(与 D6「用户自行决定,不做硬限制」一致);单档禁用在
                        // memoryWarning(for:) 内保留。
                        if let warning = selectedMemoryWarning(for: chosenVariant) {
                            Text(warning)
                                .font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
                                .accessibilityIdentifier("\(accessibilityPrefix).model.selectedMemoryWarning.\(choice.rawValue)")
                        }
                    }
                } else if let update {
                    Button(L10n.asrModelUpdate(update.version)) { startInstall(update) }
                        .buttonStyle(.bordered).frame(minHeight: metrics.touchTarget)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.update.\(choice.rawValue)")
                } else if let latest, installed == nil {
                    Button(L10n.asrModelDownload) { startInstall(latest) }
                        .buttonStyle(.bordered).frame(minHeight: metrics.touchTarget)
                        .disabled(memoryWarning(for: variants) != nil)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.download.\(choice.rawValue)")
                }
                // 2026-10-05 删除（第 6 项）：已装模型可删（家族级，含全部档位与版本），
                // 释放空间；随包模型无 installed 行不显示。删除失败如实提示可重试。
                if installed != nil {
                    Button(L10n.asrModelDelete) { pendingConfirm = .delete(choice) }
                        .buttonStyle(.bordered)
                        .tint(Color("semantic-danger", bundle: .main))
                        .frame(minHeight: metrics.touchTarget)
                        .accessibilityIdentifier("\(accessibilityPrefix).model.delete.\(choice.rawValue)")
                    if deleteFailed.contains(choice.rawValue) {
                        Text(L10n.asrModelDeleteFailed)
                            .font(.caption).foregroundStyle(Color("semantic-warning", bundle: .main))
                            .accessibilityIdentifier("\(accessibilityPrefix).model.deleteFailed.\(choice.rawValue)")
                    }
                }
            }
        }
    }

    /// 档位显示名：目录 JSON 的 `tierName` 优先（2026-10-05 业主定：文字描述由 CI
    /// 目录提供），旧目录/缺字段回落 L10n small/medium/large 映射；两者皆无回显原始档名。
    private func tierDisplayName(_ variant: String?, variants: [ASRModelRelease]) -> String {
        variants.first { $0.variant == variant }?.tierName?.resolved()
            ?? L10n.asrModelVariantName(variant ?? "")
    }

    /// 删除执行（经安装中心：服务删除 → 引擎逐出 → deferred 补删 → 资产广播）。
    private func deleteModel(_ choice: VoiceEngineChoice) {
        deleteFailed.remove(choice.rawValue)
        Task {
            do {
                try await installCenter.delete(choice)
                derivationEpoch += 1   // 重算派生结论（installed 行消失）
            } catch {
                deleteFailed.insert(choice.rawValue)
            }
        }
    }

    /// 尺寸选择绑定（2026-10-05 第 9 项：默认 = 系统推荐档——内存预算可装的最大档，
    /// 探针不可用回落 RAM 建议 → 最小档；此前恒默认最小档，≥4GB 设备也要手动改选；
    /// 选择记忆在页内）。2026-10-05 委员会增补:已装档优先于推荐档——picker 语义是
    /// 「当前状态选择器」,已装 small 的设备进页默认选中 large 会诱导 GB 级误下载;
    /// 推荐职责由 variantHint 行独立承担,回退序 = 页内选择 → 已装档 → 推荐档。
    private func variantBinding(_ choice: VoiceEngineChoice, _ variants: [ASRModelRelease],
                                installedVariant: String?) -> Binding<String> {
        Binding(get: {
            selectedVariant[choice.rawValue]
                ?? variants.first { $0.variant == installedVariant }?.variant
                ?? variants[recommendedIndex(for: variants)].variant
                ?? ""
        }, set: { v in
            selectedVariant[choice.rawValue] = v
        })
    }

    /// 业主裁决 D6：按设备 RAM 给出建议（用户自行决定，不做硬限制）。
    /// 建议规则在 Domain `ASRVariantRecommendation.variantIndex`（BR 规则不进视图）；
    /// 视图只取建议下标 + 格式化。清单已按 variantWeight 大小升序。
    /// iOS 26+ 可经 continued processing 切后台续跑（与 `BackgroundWorkScheduler.runContinued` 同判据）。
    private static var supportsContinuedProcessing: Bool {
        if #available(iOS 26, *) { return true } else { return false }
    }

    /// 推荐档下标（2026-10-05 第 9 项）：Domain 纯函数 `recommendedIndex`——
    /// 预算可装最大档优先，探针不可用回落 RAM 建议（D6），再回落最小档。
    /// 未知体积按 Int64.max（预算判定不可载、不误推荐）。
    private func recommendedIndex(for variants: [ASRModelRelease]) -> Int {
        ASRVariantRecommendation.recommendedIndex(
            expandedBytes: variants.map { $0.expandedBytes ?? Int64.max },
            availableBytes: ProcessMemory.availableBytes(),
            ramBytes: ProcessInfo.processInfo.physicalMemory)
    }

    private func variantHint(for variants: [ASRModelRelease]) -> String? {
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        guard let rec = variants[recommendedIndex(for: variants)].variant else { return nil }
        return L10n.asrModelVariantHint(rec, "\(ramBytes / 1024 / 1024 / 1024)")
    }

    /// 多档家族按所选档的内存预算预警（R3，2026-10-05 委员会）：只预警不禁用，
    /// 与 D6「用户自行决定，不做硬限制」一致；单档家族的禁用语义留在 memoryWarning(for:)。
    private func selectedMemoryWarning(for release: ASRModelRelease) -> String? {
        guard let bytes = release.expandedBytes, bytes > 0,
              case .insufficient(let required, let available) = ModelMemoryBudget.verdict(
                modelBytes: bytes, availableBytes: ProcessMemory.availableBytes()) else { return nil }
        return L10n.voicenoteDictationInsufficientMemory(
            requiredGB: String(format: "%.1f", Double(required) / 1_073_741_824),
            availableGB: String(format: "%.1f", Double(available) / 1_073_741_824))
    }

    /// 单档家族的内存预算预警（2026-10-05 第 9 项）：唯一可下载档不可载时
    /// 如实预警 + 禁用下载——防「下载完才在按压时报内存不足」（与预算门同源判定）。
    private func memoryWarning(for variants: [ASRModelRelease]) -> String? {
        guard variants.count == 1, let bytes = variants[0].expandedBytes, bytes > 0,
              case .insufficient(let required, let available) = ModelMemoryBudget.verdict(
                modelBytes: bytes, availableBytes: ProcessMemory.availableBytes()) else { return nil }
        return L10n.voicenoteDictationInsufficientMemory(
            requiredGB: String(format: "%.1f", Double(required) / 1_073_741_824),
            availableGB: String(format: "%.1f", Double(available) / 1_073_741_824))
    }

    /// 进行态视图：下载 = 分数进度 + 字节数字（慢链路下条位移缓慢，数字给确定反馈）；
    /// 校验/解压/安装/清理 = 不确定进度 + 阶段文案（此前这些阶段完全无反馈）。
    /// 2026-09-19 审查修复：新增**排队等待态**——并发槽满（最多 2 个同时下载）时
    /// 后续点击不再报「下载失败/网络错误」，如实呈现「排队等待下载槽位」。
    @ViewBuilder
    private func installProgress(_ choice: VoiceEngineChoice, _ active: ASRInstallCenter.Install) -> some View {
        if active.waiting {
            ProgressView().frame(maxWidth: 260)
            Text(L10n.asrModelQueued)
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix).model.queued.\(choice.rawValue)")
        } else if let progress = active.progress, active.phase == .downloading {
            ProgressView(value: progress.fraction).frame(maxWidth: 260)
            Text(L10n.asrModelProgress(
                ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file),
                ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)))
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix).model.progress.\(choice.rawValue)")
        } else if let progress = active.progress, active.phase == .verifying || active.phase == .unpacking {
            // 校验/解压自 2026-09-16 起也报进度（此前只能转不确定 spinner，GB 级包
            // 数十秒无反应 → 业主判定「卡死/进度条没反应」）。**只出条、不出字节数字**：
            // 此处的字节是「已处理量」而非「已下载量」，复用「已下载 X/Y」文案会误导。
            ProgressView(value: progress.fraction).frame(maxWidth: 260)
            Text(phaseText(active.phase))
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix).model.phase.\(choice.rawValue)")
        } else {
            ProgressView().frame(maxWidth: 260)
            Text(phaseText(active.phase))
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix).model.phase.\(choice.rawValue)")
        }
        // round5 Q2：后台事实按系统版本如实呈现——iOS 26 continued processing 可续跑；更早只有 ≈30 秒宽限
        Text(Self.supportsContinuedProcessing ? L10n.asrModelBackgroundHint : L10n.asrModelForegroundHint)
            .font(.caption2).foregroundStyle(.tertiary)
        Button(L10n.commonCancel) { installCenter.cancel(choice) }
            .frame(minHeight: metrics.touchTarget)
            .accessibilityIdentifier("\(accessibilityPrefix).model.cancel.\(choice.rawValue)")
    }

    private func phaseText(_ phase: ASRModelDownloadService.InstallPhase?) -> String {
        switch phase {
        case .verifying: return L10n.asrModelPhaseVerifying
        case .unpacking: return L10n.asrModelPhaseUnpacking
        case .activating: return L10n.asrModelPhaseActivating
        case .pruning: return L10n.asrModelPhasePruning
        case .downloading, nil: return L10n.asrModelDownloading
        }
    }

    /// 检查更新的总时限：索引是几 KB 的 JSON，30s 无果即判失败。
    /// 为什么必须有时限（业主 2026-09-16 第 4 项「点击检查更新出现闪退或者死机」）：
    /// 索引请求与 GB 级下载**共用同一个会话**，而该会话刻意不设资源超时
    /// （`timeoutIntervalForResource` 默认 7 天，下载不能有天花板）——链路中途
    /// 停住时按钮会一直转圈且被 `.disabled` 锁死（唯一的请求级 30s 空档计时
    /// 只要来一个字节就被重置），用户读到的就是「死机」，且页内没有任何出路。
    private static let indexCheckTimeout: Duration = .seconds(30)

    /// 在途索引拉取任务（审查修复 2026-09-18：单飞 + 视图生命周期绑定）——
    /// 原火忘任务离开页面仍在跑（可能持锁验签/落盘），返回页面时与
    /// `.task` 的派生结论重算在主线程上互踩那把锁（冻结→看门狗强杀的
    /// 成因之一）。单飞防连点双任务；onDisappear 取消。
    @State private var refreshTask: Task<Void, Never>?

    /// 「检查更新」按钮显式触发（安全审查 2026-09-12）：每次点击都真实重拉；
    /// 结果三元反馈（2026-09-16）：已是最新 / 发现 N 个可更新 / 失败可重试。
    private func refreshIndex() async {
        checkState = .checking
        let fetch = Task { try await service.fetchIndex(from: ASRModelDownloadService.indexURL) }
        // 看门狗：超时即取消请求（`metadata` 逐字节遍历里有 `Task.checkCancellation()`，
        // 取消能真正中断），按钮回到「失败可重试」而不是永久转圈
        let watchdog = Task {
            do { try await Task.sleep(for: Self.indexCheckTimeout) } catch { return }   // 正常路径下被取消
            fetch.cancel()
        }
        defer { fetch.cancel(); watchdog.cancel(); refreshTask = nil }
        do {
            let fetched = try await fetch.value
            // 离场取消出口（2026-09-28 评审修复）：onDisappear 取消的是外层
            // refreshTask，内层非结构化 fetch 不继承取消——结果到达时不再写回
            // 已离场视图的 @State（30s 看门狗窗口内）。
            guard !Task.isCancelled else { return }
            index = fetched
            derivationEpoch += 1   // 新索引 → 重算派生结论（`.task(id:)` 据此重跑）
            // 该索引下、与本 App 版本兼容且已授权的新装/更新条目数。
            let count = VoiceEngineChoice.allCases.reduce(into: 0) { total, choice in
                let latest = ASRModelDownloadService.latest(for: choice, in: fetched, appVersion: appVersion)
                let update = ASRModelDownloadService.updateAvailable(for: choice, index: fetched, appVersion: appVersion)
                let isNewInstall = latest != nil && ASRModelDownloadService.installedVersion(for: choice) == nil
                if update != nil || isNewInstall { total += 1 }
            }
            checkState = count > 0 ? .updates(count) : .upToDate
        } catch {
            // 拉取失败保留旧索引（若有）：更新/下载按钮仍可用。
            checkState = .failed
        }
    }

    private func startInstall(_ release: ASRModelRelease) {
        // 2026-09-20 修复：以信任库的**授权基址**为准（服务层 performInstall 按
        // trust.baseURL(for:) 比对——此前传页内索引的 baseUrl，与签名根信封的
        // assetBaseURL 不一致时每击必报 badAddress，用户只见「下载失败」）。
        // 索引 baseUrl 仅在无网络目录授权（测试/基线）时兜底。
        let base = ModelCatalogTrustStore.shared.baseURL(for: release)
            ?? (index ?? ModelCatalogTrustStore.shared.baselineIndex)?.baseUrl.flatMap(URL.init(string:))
        // 启动/取消/进度/后台窗口/资产广播全在中心（App 层）——本页只提供索引与授权上下文。
        installCenter.start(release, baseURL: base)
    }
}
