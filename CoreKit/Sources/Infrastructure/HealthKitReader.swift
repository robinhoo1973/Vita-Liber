#if os(iOS)
// linux-blind: HealthKit 读/写 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation
import HealthKit
import Domain
import Protocols

/// Read-only HealthKit adapter. Read authorization is deliberately not observable by apps.
/// 写回（HealthWritingProvider）与读取同体但契约分离——同一 HKHealthStore 实例双协议注入。
public actor HealthKitReader: HealthReadingProvider, HealthWritingProvider {
    private let store: HKHealthStore
    private var observers: [HKObserverQuery] = []
    public init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    /// round2 H3：删 `authorizationDenied`——读取权限对 App 不可观察，「未拒绝」不是证据；
    /// `requestIncomplete` 只表达「系统授权流程尚未完成」这一可观察事实。
    public enum ReaderError: Error { case unavailable, requestIncomplete, invalidAnchor, incompleteSnapshot }

    /// 本应用自己的 bundle 标识（写回防回声：自己写入 HealthKit 的样本不得再导回——
    /// 否则写回样本经增量同步回灌 metric_sample 形成重复行、再写回形成环路）。
    private static let ownBundleID: String? = Bundle.main.bundleIdentifier

    /// 样本是否为本应用写入（防回声过滤；写回关闭时本谓词恒假、零开销）。
    private static func isOwnSample(_ sample: HKSample) -> Bool {
        guard let ownBundleID else { return false }
        return sample.sourceRevision.source.bundleIdentifier == ownBundleID
    }

    public static var readTypes: Set<HKObjectType> {
        var types = Set(HealthDataKind.allCases.map { sampleType($0) as HKObjectType })
        // 特征型（血型/出生日期/生理性别）：**读**集合里声明即可（写集合里放特征型不会出现在授权单上）；
        // 用户未填不报错，读取时抛错由 characteristics() 如实转成 nil。
        types.formUnion(Self.characteristicTypes)
        return types
    }

    private static var characteristicTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for identifier: HKCharacteristicTypeIdentifier in [.bloodType, .dateOfBirth, .biologicalSex] {
            if let type = HKObjectType.characteristicType(forIdentifier: identifier) { types.insert(type) }
        }
        return types
    }

    private static func sampleType(_ kind: HealthDataKind) -> HKSampleType {
        switch kind {
        case .heartRate: return HKQuantityType(.heartRate)
        case .restingHeartRate: return HKQuantityType(.restingHeartRate)
        case .bloodOxygen: return HKQuantityType(.oxygenSaturation)
        case .respiratoryRate: return HKQuantityType(.respiratoryRate)
        case .steps: return HKQuantityType(.stepCount)
        case .sleep: return HKCategoryType(.sleepAnalysis)
        }
    }

    // MARK: - 写回（业主 2026-09-17 定：本机确认的手输指标 → HealthKit）

    /// 可写类型 = Domain `HealthWriteBack.canonicalUnit` 的指标集（单位匹配的唯一对照）。
    public static var writeTypes: Set<HKSampleType> {
        Set([MetricType.bloodPressureSys, .bloodPressureDia, .glucose, .weight,
             .temperature, .heartRate, .bloodOxygen].compactMap { hkQuantityType($0) as HKSampleType? })
    }

    private static func hkQuantityType(_ metric: MetricType) -> HKQuantityType? {
        switch metric {
        case .bloodPressureSys: return HKQuantityType(.bloodPressureSystolic)
        case .bloodPressureDia: return HKQuantityType(.bloodPressureDiastolic)
        case .glucose: return HKQuantityType(.bloodGlucose)
        case .weight: return HKQuantityType(.bodyMass)
        case .temperature: return HKQuantityType(.bodyTemperature)
        case .heartRate: return HKQuantityType(.heartRate)
        case .bloodOxygen: return HKQuantityType(.oxygenSaturation)
        default: return nil
        }
    }

    private static func hkUnit(_ metric: MetricType) -> HKUnit? {
        switch metric {
        case .bloodPressureSys, .bloodPressureDia: return .millimeterOfMercury()
        case .glucose: return .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        case .weight: return .gramUnit(with: .kilo)
        case .temperature: return .degreeCelsius()
        case .heartRate: return .count().unitDivided(by: .minute())
        case .bloodOxygen: return .percent()
        default: return nil
        }
    }

    /// 写回尺度：**应用内部值 → HealthKit 单位期望值**。规则本体在 Domain
    /// `HealthWriteBack.writeScale`（与 `canonicalUnit`/`isWritable` 同一出口，且本机可测）；
    /// 此处只做 `MetricType` → metric 字符串的转接。
    private static func hkWriteScale(_ metric: MetricType) -> Double {
        HealthWriteBack.writeScale(for: metric.rawValue)
    }

    public func requestWriteAuthorization() async throws {
        guard isAvailable() else { throw HealthWriteError.unavailable }
        try await store.requestAuthorization(toShare: Self.writeTypes, read: [])
        // 同读取侧纪律：只回答「流程是否已完成」；是否获准由 writeAuthorizationStatus() 观察。
        let status = try await store.statusForAuthorizationRequest(toShare: Self.writeTypes, read: [])
        guard status == .unnecessary else { throw HealthWriteError.requestIncomplete }
    }

    public func writeAuthorizationStatus() async -> HealthWriteAuthStatus {
        guard isAvailable() else { return .notDetermined }
        var anyDenied = false
        var allGranted = true
        for type in Self.writeTypes {
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized: break
            case .sharingDenied: anyDenied = true; allGranted = false
            default: allGranted = false
            }
        }
        if allGranted { return .granted }
        return anyDenied ? .denied : .notDetermined
    }

    /// 写回样本。单位不符/类型不可写的条目**跳过**（Domain `HealthWriteBack.isWritable`
    /// 单一事实源）；收缩压携第二值时合并为血压相关性对象（Health 里的规范呈现形态），
    /// 其余写入单值样本。只返回实际写入条数。
    public func writeBack(_ samples: [HealthSampleDraft]) async throws -> Int {
        guard isAvailable() else { throw HealthWriteError.unavailable }
        var objects: [HKObject] = []
        var written = 0
        for draft in samples {
            guard draft.measuredAt.timeIntervalSince1970.isFinite,
                  HealthWriteBack.isWritable(metric: draft.metric, unit: draft.unit, value: draft.value),
                  let metric = MetricType(rawValue: draft.metric) else { continue }
            let date = draft.measuredAt
            if metric == .bloodPressureSys, let dia = draft.secondaryValue, dia.isFinite {
                guard let sysType = Self.hkQuantityType(.bloodPressureSys),
                      let diaType = Self.hkQuantityType(.bloodPressureDia) else { continue }
                let sys = HKQuantitySample(type: sysType,
                    quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: draft.value),
                    start: date, end: date)
                let diaSample = HKQuantitySample(type: diaType,
                    quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: dia),
                    start: date, end: date)
                objects.append(HKCorrelation(type: HKCorrelationType(.bloodPressure),
                                             start: date, end: date,
                                             objects: Set<HKSample>(arrayLiteral: sys, diaSample)))
                written += 1
            } else {
                guard let type = Self.hkQuantityType(metric), let unit = Self.hkUnit(metric) else { continue }
                objects.append(HKQuantitySample(type: type,
                    quantity: HKQuantity(unit: unit,
                                         doubleValue: draft.value * Self.hkWriteScale(metric)),
                    start: date, end: date))
                written += 1
            }
        }
        guard !objects.isEmpty else { return 0 }
        do {
            try await store.save(objects)
            return written
        } catch let error as HKError {
            throw error.code == .errorAuthorizationNotDetermined ? HealthWriteError.requestIncomplete
                                                                  : HealthWriteError.failed
        } catch {
            throw HealthWriteError.failed
        }
    }

    public func isAvailable() -> Bool { HKHealthStore.isHealthDataAvailable() }

    public func requestAuthorization() async throws {
        guard isAvailable() else { throw ReaderError.unavailable }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
        // round2 H3：statusForAuthorizationRequest 只回答「系统流程是否已完成」
        // （.unnecessary = 已完成、.shouldRequest = 未完成）。读取权限对 App 不可观察：
        // 完成 ≠ 获准，未完成 ≠ 拒绝——旧实现把 .unnecessary 当「未拒绝」证据并把其余
        // 映射成 authorizationDenied，两者皆为臆断。这里只如实上报「流程未完成」。
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        guard status == .unnecessary else { throw ReaderError.requestIncomplete }
    }

    /// 仅特征型的授权请求（首启注册预填的最小请求——系统授权单只出现健康档案资料）。
    public func requestCharacteristicAuthorization() async throws {
        guard isAvailable() else { throw ReaderError.unavailable }
        try await store.requestAuthorization(toShare: [], read: Self.characteristicTypes)
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: Self.characteristicTypes)
        guard status == .unnecessary else { throw ReaderError.requestIncomplete }
    }

    /// 特征型读取（业主 2026-09-17 定：导入走档案候选）。
    ///
    /// **用户没填 ≠ 失败**：Health 里未设置时 `bloodType()` 等会抛错——那是「没有这份数据」，
    /// 如实按 nil 呈现，绝不编造、绝不猜（来源与精度都随 Health 的填法）。
    public func characteristics() async throws -> HealthCharacteristics {
        guard isAvailable() else { throw ReaderError.unavailable }
        var result = HealthCharacteristics()
        do { result.bloodType = Self.format(try store.bloodType().bloodType) } catch { result.bloodType = nil }
        do { result.gender = Self.format(try store.biologicalSex().biologicalSex) } catch { result.gender = nil }
        do { result.birthDate = Self.format(try store.dateOfBirthComponents()) } catch { result.birthDate = nil }
        return result
    }

    /// 血型：国际简写（`A+` / `AB−`…）。Health 的 `.notSet` 归 nil。
    private static func format(_ blood: HKBloodType) -> String? {
        switch blood {
        case .aPositive: return "A+"
        case .aNegative: return "A−"
        case .bPositive: return "B+"
        case .bNegative: return "B−"
        case .abPositive: return "AB+"
        case .abNegative: return "AB−"
        case .oPositive: return "O+"
        case .oNegative: return "O−"
        default: return nil
        }
    }

    /// 生理性别：Health 三档原样透传（`male` / `female` / `other`），到档案前由用户确认。
    private static func format(_ sex: HKBiologicalSex) -> String? {
        switch sex {
        case .male: return "male"
        case .female: return "female"
        case .other: return "other"
        default: return nil
        }
    }

    /// 出生日期：`yyyy-MM-dd`；Health 里只填了年份时给 `yyyy`（精度随来源，不擅自细化）。
    private static func format(_ components: DateComponents) -> String? {
        guard let year = components.year else { return nil }
        guard let month = components.month, let day = components.day else { return String(format: "%04d", year) }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 后台投递注册结果（2026-09-23 修复）：不能再把「某类型未授权/被拒」与「注册整体失败」
    /// 混为一个布尔——健康读取权限**按类型**授予、用户可逐类拒绝；任何单类型失败都把整体
    /// 判死，会让警示横幅在部分授权用户处永久点亮（「重新连接」也无法修复被拒类型）。
    public struct BackgroundDeliveryOutcome: Sendable, Equatable {
        /// 已开启后台投递的样本类型（`HKSampleType.identifier`）。
        public var armedTypes: [String] = []
        /// 权限未定/被拒——用户侧修复（重新走连接授权单，或到「健康」App 调整读取权限）。
        public var blockedTypes: [String] = []
        /// 其他系统错误——可重试。
        public var failedTypes: [String] = []
        /// 后台自动导入可用 = 至少一个类型已武装。
        public var isUsable: Bool { !armedTypes.isEmpty }
        public init() {}
    }

    public func observeChanges(handler: @escaping @Sendable () async -> Bool,
                               enableDelivery: Bool) async -> BackgroundDeliveryOutcome {
        if observers.isEmpty {
            for type in Self.readTypes {
                guard let sampleType = type as? HKSampleType else { continue }
                let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, error in
                    Task {
                        if error == nil { _ = await handler() }
                        completion()
                    }
                }
                observers.append(query)
                store.execute(query)
            }
        }
        var outcome = BackgroundDeliveryOutcome()
        for type in Self.readTypes {
            guard let sampleType = type as? HKSampleType else { continue }
            let identifier = sampleType.identifier
            do {
                if enableDelivery {
                    try await store.enableBackgroundDelivery(for: type, frequency: .hourly)
                    outcome.armedTypes.append(identifier)
                } else {
                    try await store.disableBackgroundDelivery(for: type)
                }
            } catch let error as HKError {
                // 权限族（未定/被拒）≠ 注册缺陷：逐类型分类留证，单类型被拒只封锁该类型。
                switch error.code {
                case .errorAuthorizationDenied, .errorAuthorizationNotDetermined:
                    if enableDelivery { outcome.blockedTypes.append(identifier) }
                default:
                    if enableDelivery { outcome.failedTypes.append(identifier) }
                }
            } catch {
                if enableDelivery { outcome.failedTypes.append(identifier) }
            }
        }
        return outcome
    }

    /// round2 H-N1：按分道谓词分页——HKAnchoredObjectQuery 行序最旧优先且不可倒序。
    /// **2026-09-19 审查修复（业主实测「最近数据导入不到」的根因）**：锚点式排空让
    /// 最新样本永远排在最后一页——一年心率 ≈1000 页 × 每轮 1 页/类，最新数据需要
    /// 数百次同步才到达，窗口重排（HealthKitSyncService）只能重排**已到达**的窗口。
    /// recent 道改**降序首填**（HKSampleQuery 按 startDate 降序 + 日窗口分片，最新先到），
    /// 排空后经一次转锚点查询切回锚点增量（删除证明自此完整送达）；history 道维持
    /// 锚点式最旧优先（锚点推进语义不变）。游标各自编码进 hk_sync_anchor 的 Data 载荷：
    /// recent = JSON（RecentLaneCursor，v4 键空间），history = NSKeyedArchiver(HKQueryAnchor)。
    public func changes(for kind: HealthDataKind, scope: HealthFetchScope, anchor: Data?, limit: Int) async throws -> HealthChangeBatch {
        try Task.checkCancellation()
        guard isAvailable() else { throw ReaderError.unavailable }
        guard limit > 0, limit <= 500 else { throw ReaderError.incompleteSnapshot }
        if scope.lane == .recent {
            return try await recentLaneChanges(kind: kind, scope: scope, anchor: anchor, limit: limit)
        }
        return try await anchoredChanges(kind: kind, scope: scope, anchor: anchor, limit: limit)
    }

    /// 锚点式分页（history 道与 recent 道增量期共用）。`predicate` 覆盖仅用于
    /// recent 道转锚点与增量（窄谓词 = 道谓词 ∧ start ≥ newestStart − 7d——转锚点
    /// 查询只命中首填期间新到样本，锚点定位在流末端，首填前数据不会重投；
    /// 增量与转锚点**同谓词**，锚点始终在同一谓词家族内使用）。
    private func anchoredChanges(kind: HealthDataKind, scope: HealthFetchScope, anchor: Data?, limit: Int,
                                 predicate: NSPredicate? = nil) async throws -> HealthChangeBatch {
        let cursor: HKQueryAnchor?
        if let anchor {
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor) else {
                throw ReaderError.invalidAnchor
            }
            cursor = decoded
        } else { cursor = nil }
        let query = HKAnchoredObjectQueryDescriptor(
            predicates: [HKSamplePredicate.sample(type: Self.sampleType(kind),
                                                  predicate: predicate ?? Self.changePredicate(for: scope))],
            anchor: cursor, limit: limit)
        let result = try await query.result(for: store)
        try Task.checkCancellation()
        // 审查修复：added+deleted 合计超限即抛错——limit 只约束新增样本页，
        // 删除对象随锚点窗口整体返回。新增满页（500）且用户删过 1 条样本
        // 时恒抛 incompleteSnapshot、锚点永不前进、同批删除每轮重报——
        // 该类型从此永久卡死（无恢复路径）。分页只看 added，deleted 不
        // 参与限流判定。
        guard result.addedSamples.count <= limit else { throw ReaderError.incompleteSnapshot }
        // 防回声：自己写回 HealthKit 的样本不进增量通道；其墓碑一并过滤——
        // 写回样本从未入库，对应的删除证明无窗口可重算、纯属浪费。
        let ownSampleIDs = Set(result.addedSamples.filter(Self.isOwnSample).map(\.uuid))
        let added = try result.addedSamples
            .filter { !Self.isOwnSample($0) }.map { try Self.reference($0, kind: kind) }
        let deleted = result.deletedObjects.filter { !ownSampleIDs.contains($0.uuid) }.map(\.uuid)
        // hasMore 必须由**过滤后的批次**导出，不能由原始查询结果导出。
        // 反例（本修复的由来）：整页样本都是本应用自己写回的 → 过滤后 added/deleted 皆空，
        // 而原始结果非空 ⇒ hasMore=true。此时 `HealthImportStore.stage` 的
        // 「hasMore 却无内容可入」守卫会抛 invalidValue，而锚点只在 commit 时前进，
        // 于是**该类型的导入永久卡死**：此后所有真样本（如新手表测量）都排在
        // 这个消费不掉的页后面，同步永远报「部分类型导入失败」，用户只能在健康 App
        // 里删掉自己的样本才可能恢复。heartRate/bloodOxygen 同时在写回与读取两端，
        // 开启写回后手存一次血氧即可构造。
        // 安全性：锚点取 result.newAnchor（覆盖整页原始结果），故 hasMore=false 只是
        // 本轮不再续拉，下一轮同步从新锚点继续，**不会漏样本**。
        // 全页删除时 deleted 非空 ⇒ hasMore 仍为 true，原「mostly deletions」语义保留。
        // 2026-09-19 扫尾结论修正：`result.newAnchor` 为非可选 HKQueryAnchor
        //（macOS 编译实证 CI 35438751674）——零结果也会返回有效锚点，
        // 「nil 锚点毒化」路径不存在，恢复原始直归档形态。
        return HealthChangeBatch(
            added: added,
            deleted: deleted,
            anchor: try NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true),
            hasMore: !added.isEmpty || !deleted.isEmpty)
    }

    // MARK: - recent 道降序首填（2026-09-19 修复「最近数据导入不到」）

    /// recent 道游标（JSON 编码，借锚点 Data 载荷持久化）。三态：
    /// descending = 日窗口降序首填中；fillComplete = 首填完成、下一拍转锚点；
    /// anchored = 增量期（hkAnchor = NSKeyedArchiver(HKQueryAnchor)）。
    /// 解码失败（旧格式/损坏）按「重新首填」处理——降序首填按样本 id 幂等重排，自愈。
    struct RecentLaneCursor: Codable {
        enum Mode: String, Codable { case descending, fillComplete, anchored }
        var mode: Mode
        /// 当前（半开）取数窗口 [windowStart, windowEnd)（样本 startDate 域）
        var windowStart: Date?
        var windowEnd: Date?
        /// 当前窗口的日界下沿（窗口内收缩分片后排空本日剩余用）
        var dayStart: Date?
        /// 首填首页钉下的全道最新样本起点（转锚点/增量的窄谓词下界；全道零样本
        /// 时为 nil → 转锚点谓词以当前时刻为下界）。
        var newestStart: Date?
        /// anchored 期：归档的 HKQueryAnchor
        var hkAnchor: Data?
    }

    /// 首填完成边界：窗口下沿越过 cutoff 再留 48h 余量（跨窗睡眠样本的 start 可早于
    /// cutoff——道谓词 end >= cutoff 会滤掉无跨窗者，余量窗口恒返回空页/跨窗者）。
    private static let fillStraddleMargin: TimeInterval = 172_800
    /// 增量窄谓词的下界余量：newestStart − 7d——首填期间的迟达样本（Watch 晚同步/
    /// 回填时间戳）在 7 天窗口内由转锚点查询兜住；更深回填登记为已知边界。
    private static let incrementalOverlap: TimeInterval = 7 * 86_400

    /// 增量谓词 = **完整道谓词**（2026-09-19 扫尾修正）：窄谓词（start ≥ newestStart−7d）
    /// 会永久遮蔽首填区间内被用户在健康 App 删除的样本的墓碑——本地行永不删除、
    /// 继续污染趋势与告警证据（BR-004 事实链）。全道谓词下删除证明完整送达；
    /// 转锚点 nil 锚点查询会把首填数据重投一遍，但提交按身份幂等 upsert，不产重复行
    /// （HealthImportStore.commit 契约），一次性成本换取删除保真。
    /// 注：HealthKit 谓词按 **startDate** 过滤（predicateForSamples(withStart:)），
    /// Domain 道契约为 end ≥ cutoff——跨 cutoff 的样本（start < cutoff ≤ end）归
    /// history 道，recent 首填的 48h 余量窗口使边界样本双道幂等覆盖（已知边界）。
    private static func incrementalPredicate(for scope: HealthFetchScope, newestStart: Date?) -> NSPredicate {
        changePredicate(for: scope)
    }

    private func recentLaneChanges(kind: HealthDataKind, scope: HealthFetchScope, anchor: Data?, limit: Int) async throws -> HealthChangeBatch {
        var cursor: RecentLaneCursor?
        if let anchor {
            cursor = try? JSONDecoder().decode(RecentLaneCursor.self, from: anchor)   // try?-ok: 解码失败回落首填（幂等自愈）
        }
        switch cursor?.mode ?? .descending {
        case .anchored:
            guard let hkAnchor = cursor?.hkAnchor else {
                // 归档锚点缺失 = 游标损坏：重新首填（幂等）
                return try await descendingPage(kind: kind, scope: scope, cursor: nil, limit: limit)
            }
            return try await anchoredChanges(kind: kind, scope: scope, anchor: hkAnchor, limit: limit,
                                             predicate: Self.changePredicate(for: scope))
        case .fillComplete:
            // 转锚点：nil 锚点 + 窄谓词跑一次——只命中首填期间新到样本；样本**照常入批**
            // （丢弃会丢数据：它们在锚点之前，后续增量不可见），锚点换成归档 newAnchor
            // （流末端位置），此后增量与转锚点同谓词、删除证明完整送达。
            let bootstrap = try await anchoredChanges(kind: kind, scope: scope, anchor: nil, limit: limit,
                                                      predicate: Self.changePredicate(for: scope))
            // 2026-09-19 扫尾结论修正：bootstrap.anchor 非可选（见 anchoredChanges），
            // 转锚点必然成功归档，恢复直进 anchored 模式。
            var done = cursor ?? RecentLaneCursor(mode: .fillComplete)
            done.mode = .anchored
            done.hkAnchor = bootstrap.anchor
            return HealthChangeBatch(added: bootstrap.added, deleted: bootstrap.deleted,
                                     anchor: try Self.encodeCursor(done), hasMore: bootstrap.hasMore)
        case .descending:
            return try await descendingPage(kind: kind, scope: scope, cursor: cursor, limit: limit)
        }
    }

    /// 日窗口降序页：窗口 [windowStart, windowEnd) 内样本按 startDate 降序；窗口样本数
    /// 超限时窗口自适应折半（有界推进——1 秒心率可上万样本）；空窗口**同调用内连续
    /// 推进**（整年零样本不必 365 轮空转）；窗口排空后向旧推进一天。
    private func descendingPage(kind: HealthDataKind, scope: HealthFetchScope, cursor: RecentLaneCursor?, limit: Int) async throws -> HealthChangeBatch {
        var windowEnd = cursor?.windowEnd ?? Date().addingTimeInterval(86_400)
        var windowStart = cursor?.windowStart ?? windowEnd.addingTimeInterval(-86_400)
        var dayStart = cursor?.dayStart ?? windowStart
        var newestStart = cursor?.newestStart
        while true {
            try Task.checkCancellation()
            // 首填完成判定：窗口下沿越过 cutoff − 48h 余量（跨窗样本覆盖）
            if windowEnd <= scope.cutoff.addingTimeInterval(-Self.fillStraddleMargin) {
                var done = RecentLaneCursor(mode: .fillComplete)
                done.windowStart = windowStart
                done.windowEnd = windowEnd
                done.dayStart = dayStart
                done.newestStart = newestStart
                return HealthChangeBatch(added: [], deleted: [],
                                         anchor: try Self.encodeCursor(done), hasMore: false)
            }
            let samples = try await descendingSamples(kind: kind, scope: scope,
                                                      start: windowStart, end: windowEnd,
                                                      limit: limit + 1)
            if samples.count > limit {
                let span = windowEnd.timeIntervalSince(windowStart)
                if span <= 1 {
                    // 病理：同一 startDate 秒内超过一页（多源同刻）。取最新 limit 条、
                    // 余者让位（有界推进优先；此类样本在增量期不再补）。
                    let page = try Array(samples.prefix(limit)).map { try Self.reference($0, kind: kind) }
                    var pageCursor = Self.advancedCursor(windowStart: windowStart, dayStart: dayStart)
                    pageCursor.newestStart = newestStart ?? samples.first?.startDate
                    return HealthChangeBatch(added: page, deleted: [],
                                             anchor: try Self.encodeCursor(pageCursor),
                                             hasMore: !page.isEmpty)
                }
                windowStart = windowEnd.addingTimeInterval(-span / 2)
                continue
            }
            if newestStart == nil { newestStart = samples.first?.startDate }
            // 防回声过滤（与锚点路径同纪律）；hasMore 由过滤后批次导出
            let refs = try samples.filter { !Self.isOwnSample($0) }.map { try Self.reference($0, kind: kind) }
            let next = Self.advancedCursor(windowStart: windowStart, dayStart: dayStart)
            var nextCursor = next
            nextCursor.newestStart = newestStart
            if refs.isEmpty {
                // 空窗口（无样本/全为自身回声）：同调用内推进，不落空页
                windowEnd = next.windowEnd ?? windowEnd
                windowStart = next.windowStart ?? windowStart
                dayStart = next.dayStart ?? dayStart
                continue
            }
            return HealthChangeBatch(added: refs, deleted: [],
                                     anchor: try Self.encodeCursor(nextCursor), hasMore: true)
        }
    }

    /// 窗口排空后的游标推进：收缩分片内 → 排空本日剩余；整窗完成 → 向旧推进一天。
    private static func advancedCursor(windowStart: Date, dayStart: Date) -> RecentLaneCursor {
        var next = RecentLaneCursor(mode: .descending)
        if windowStart > dayStart {
            next.windowEnd = windowStart
            next.windowStart = dayStart
            next.dayStart = dayStart
        } else {
            next.windowEnd = windowStart
            next.dayStart = windowStart.addingTimeInterval(-86_400)
            next.windowStart = next.dayStart
        }
        return next
    }

    private static func encodeCursor(_ cursor: RecentLaneCursor) throws -> Data {
        try JSONEncoder().encode(cursor)
    }

    /// 窗口样本降序查询（HKSampleQuery 支持排序；锚点查询不可排序——正是首填改用本查询的原因）。
    private func descendingSamples(kind: HealthDataKind, scope: HealthFetchScope,
                                   start: Date, end: Date, limit: Int) async throws -> [HKSample] {
        let type = Self.sampleType(kind)
        let range = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictEndDate])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            range, Self.changePredicate(for: scope)
        ])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                                      sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    public func snapshot(for window: HealthImportWindow, calendar: Calendar) async throws -> HealthWindowSnapshot {
        try Task.checkCancellation()
        guard isAvailable() else { throw ReaderError.unavailable }
        guard window.isValid else { throw ReaderError.incompleteSnapshot }
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        // 防回声：窗口聚合同样排除自己写回的样本（否则小时均值/步数合计被自己的写回抬高）。
        let samples = try await querySamples(for: window.kind, predicate: predicate)
            .filter { !Self.isOwnSample($0) }
        let references = try samples.map { try Self.reference($0, kind: window.kind) }

        // 各指标族的行物化逐类下放（结构轮纪律：snapshot 只做分派与收口，
        // 不再 120 行四分支一方法——每族的拒绝/稀疏计数也随分支闭环）
        let rows: [DeviceMetricRow]
        let readings: [MetricReading]
        let rejected: Int
        let sparse: Int   // round2 H-N2：心率 <3 样本未成行的小时桶计数（按来源逐桶）
        switch window.kind {
        case .sleep:
            rows = Self.sleepRows(samples: samples, window: window, calendar: calendar)
            readings = []
            rejected = 0
            sparse = 0
        case .steps:
            rows = try await stepRows(samples: samples, window: window)
            readings = []
            rejected = 0
            sparse = 0
        case .heartRate:
            let result = try await heartRateRows(samples: samples, window: window, calendar: calendar)
            rows = result.rows
            readings = []
            rejected = result.rejected
            sparse = result.sparse
        default:
            let result = try await quantityRows(samples: samples, window: window)
            rows = result.rows
            readings = result.readings
            rejected = result.rejected
            sparse = 0
        }
        try Task.checkCancellation()
        return HealthWindowSnapshot(window: window, samples: references, rows: rows, readings: readings,
                                    rejected: rejected, sparseWindows: sparse)
    }

    /// 睡眠时段桶：HKCategorySample → SleepSample → SleepMerge（Domain 合并单出口）→ 六键行。
    private static func sleepRows(samples: [HKSample], window: HealthImportWindow,
                                  calendar: Calendar) -> [DeviceMetricRow] {
        let sleep = samples.compactMap { sample -> SleepSample? in
            guard let sample = sample as? HKCategorySample else { return nil }
            let stage: SleepStage
            switch sample.value {
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: stage = .deep
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue: stage = .rem
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue: stage = .core
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: stage = .unspecified
            case HKCategoryValueSleepAnalysis.awake.rawValue: stage = .awake
            case HKCategoryValueSleepAnalysis.inBed.rawValue: stage = .inBed
            default: return nil
            }
            return SleepSample(start: sample.startDate, end: sample.endDate, stage: stage,
                sourceName: sample.sourceRevision.source.name, sourceVersion: sample.sourceRevision.version,
                sourceProduct: sample.sourceRevision.productType)
        }
        let summary = SleepMerge.merge(sleep, anchorDate: window.end, calendar: calendar)
        let values: [(String, Double)] = [
            ("sleep_total", summary.totalAsleep), ("sleep_deep", summary.perStage[.deep] ?? 0),
            ("sleep_rem", summary.perStage[.rem] ?? 0), ("sleep_awake", summary.perStage[.awake] ?? 0),
            ("sleep_core", summary.perStage[.core] ?? 0), ("sleep_unspecified", summary.perStage[.unspecified] ?? 0)
        ]
        return values.compactMap { key, seconds in
            guard seconds > 0 else { return nil }
            return DeviceMetricRow(metricKey: key, value: seconds / 3600, unit: "h",
                measuredAt: window.start, sourceRef: window.prefix + key,
                aggregation: .sleepDuration, windowEnd: window.end)
        }
    }

    /// 步数日累计：HKStatistics 累积和 + 验证集与索引快照同口径比对（防回声）。
    private func stepRows(samples: [HKSample], window: HealthImportWindow) async throws -> [DeviceMetricRow] {
        guard !samples.isEmpty else { return [] }
        let ids = Set(samples.map(\.uuid))
        let statisticsPredicate = Self.stepStatisticsPredicate(for: window, sampleIDs: ids)
        try Task.checkCancellation()
        // Keep HealthKit's source arbitration, but never include a contributor absent from the index snapshot.
        let statistics = try await HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: statisticsPredicate),
            options: .cumulativeSum).result(for: store)
        try Task.checkCancellation()
        guard let value = statistics?.sumQuantity()?.doubleValue(for: .count()), value.isFinite else {
            throw ReaderError.incompleteSnapshot
        }
        // 验证集与索引快照同口径过滤自己的写回样本——谓词只按时间窗匹配，
        // 不过滤时验证集多出的自有样本会让集合比对误判 incompleteSnapshot。
        let verified = try await querySamples(for: .steps, predicate: statisticsPredicate)
            .filter { !Self.isOwnSample($0) }
        guard Set(verified.map(\.uuid)) == ids else { throw ReaderError.incompleteSnapshot }
        return [DeviceMetricRow(metricKey: "steps", value: value, unit: "count",
            measuredAt: window.start, sourceRef: window.prefix + "sum",
            aggregation: .dailySum, windowEnd: min(Date(), window.end))]
    }

    /// 心率小时均值：按来源分桶 → HourWindowAggregator（Domain）→ 每小时一行。
    private func heartRateRows(samples: [HKSample], window: HealthImportWindow,
                               calendar: Calendar) async throws -> (rows: [DeviceMetricRow], rejected: Int, sparse: Int) {
        let unit = HKUnit.count().unitDivided(by: .minute())
        let quantities = samples.compactMap { $0 as? HKQuantitySample }
        let bySource = Dictionary(grouping: quantities) { $0.sourceRevision.source.bundleIdentifier }
        var rows: [DeviceMetricRow] = []
        var rejected = 0
        var sparse = 0
        for sourceID in bySource.keys.sorted() {
            guard let contributing = bySource[sourceID] else { continue }
            var points: [HourWindowSample] = []
            for sample in contributing {
                for point in try await quantityPoints(sample, unit: unit, useEndDate: false) {
                    guard point.at >= window.start, point.at < window.end else { continue }
                    points.append(HourWindowSample(value: point.value, at: point.at))
                }
            }
            let aggregate = HourWindowAggregator.aggregate(points, calendar: calendar)
            rejected += aggregate.rejected
            sparse += aggregate.sparseWindows
            guard let summary = aggregate.windows.first else { continue }
            let revision = contributing.max { $0.endDate < $1.endDate }?.sourceRevision
            let products = Set(contributing.compactMap { $0.sourceRevision.productType })
            rows.append(DeviceMetricRow(metricKey: "heart_rate", value: summary.avg, unit: "bpm",
                valueMin: summary.min, valueMax: summary.max, sampleCount: summary.sampleCount, sourceName: revision?.source.name,
                sourceVersion: revision?.version, sourceProduct: products.count == 1 ? products.first : nil,
                measuredAt: window.start, sourceRef: window.prefix + sourceID,
                sourceIdentifier: sourceID, aggregation: .hourlyAverage,
                windowEnd: min(Date(), window.end)))
        }
        return (rows, rejected, sparse)
    }

    /// 单值族（静息心率/血氧/呼吸率）：逐样本逐点 → 行 + 读数（趋势/报警管道）。
    private func quantityRows(samples: [HKSample], window: HealthImportWindow) async throws
        -> (rows: [DeviceMetricRow], readings: [MetricReading], rejected: Int) {
        let key: String
        let unit: HKUnit
        let label: String
        let factor: Double
        switch window.kind {
        case .restingHeartRate: key = "restingHeartRate"; unit = .count().unitDivided(by: .minute()); label = "bpm"; factor = 1
        case .bloodOxygen: key = "blood_oxygen"; unit = .percent(); label = "%"; factor = 100
        default: key = "respiratory_rate"; unit = .count().unitDivided(by: .minute()); label = "br/min"; factor = 1
        }
        var rows: [DeviceMetricRow] = []
        var readings: [MetricReading] = []
        var rejected = 0
        for case let sample as HKQuantitySample in samples {
            let source = sample.sourceRevision
            for point in try await quantityPoints(sample, unit: unit, useEndDate: true) {
                guard point.at >= window.start, point.at < window.end else { continue }
                let value = point.value * factor
                guard value.isFinite else { rejected += 1; continue }
                // Window-independent identity: a later time-zone/binding change replays onto the same row.
                let identity = HealthImportWindow.sampleIdentity(kind: window.kind, sampleID: sample.uuid,
                                                                 ordinal: point.ordinal)
                rows.append(DeviceMetricRow(metricKey: key, value: value, unit: label,
                    sampleCount: 1, sourceName: source.source.name, sourceVersion: source.version,
                    sourceProduct: source.productType, measuredAt: point.at,
                    sourceRef: identity, sourceIdentifier: source.source.bundleIdentifier,
                    aggregation: .sample, windowEnd: point.at))
                readings.append(MetricReading(metricKey: key, value: value, unit: label, origin: .device,
                    measuredAt: point.at, sourceName: source.source.name, sourceVersion: source.version,
                    sourceProduct: source.productType, sourceIdentifier: source.source.bundleIdentifier,
                    sampleID: identity))
            }
        }
        return (rows, readings, rejected)
    }

    /// A condensed quantity sample is a container, not one independent reading. `ordinal` is nil for a
    /// single-quantity sample and the series entry index otherwise (identity = sample UUID + ordinal).
    private func quantityPoints(_ sample: HKQuantitySample, unit: HKUnit,
                                 useEndDate: Bool) async throws -> [(ordinal: Int?, value: Double, at: Date)] {
        try Task.checkCancellation()
        guard sample.count > 0 else { throw ReaderError.incompleteSnapshot }
        if sample.count == 1 {
            return [(nil, sample.quantity.doubleValue(for: unit),
                     useEndDate ? sample.endDate : sample.startDate)]
        }
        let query = HKQuantitySeriesSampleQueryDescriptor(
            predicate: .quantitySample(type: sample.quantityType, predicate: HKQuery.predicateForObject(with: sample.uuid)),
            options: .orderByQuantitySampleStartDate)
        var points: [(ordinal: Int?, value: Double, at: Date)] = []
        for try await entry in query.results(for: store) {
            try Task.checkCancellation()
            guard entry.dateInterval.start.timeIntervalSince1970.isFinite,
                  entry.dateInterval.end.timeIntervalSince1970.isFinite,
                  entry.dateInterval.start >= sample.startDate, entry.dateInterval.end <= sample.endDate else {
                throw ReaderError.incompleteSnapshot
            }
            points.append((points.count, entry.quantity.doubleValue(for: unit),
                           useEndDate ? entry.dateInterval.end : entry.dateInterval.start))
        }
        guard points.count == sample.count else { throw ReaderError.incompleteSnapshot }
        return points
    }

    /// Every reference query is bounded, without truncating a window or slicing an opaque anchor.
    private func querySamples(for kind: HealthDataKind, predicate: NSPredicate) async throws -> [HKSample] {
        var samples: [UUID: HKSample] = [:]
        var anchor: HKQueryAnchor?
        while true {
            try Task.checkCancellation()
            let query = HKAnchoredObjectQueryDescriptor(
                predicates: [.sample(type: Self.sampleType(kind), predicate: predicate)], anchor: anchor, limit: 500)
            let result = try await query.result(for: store)
            try Task.checkCancellation()
            guard result.addedSamples.count <= 500 else { throw ReaderError.incompleteSnapshot }
            for sample in result.addedSamples { samples[sample.uuid] = sample }
            for deleted in result.deletedObjects { samples.removeValue(forKey: deleted.uuid) }
            if result.addedSamples.isEmpty && result.deletedObjects.isEmpty { break }
            if let anchor, result.newAnchor.isEqual(anchor) { throw ReaderError.invalidAnchor }
            anchor = result.newAnchor
        }
        return samples.values.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }
    }

    /// round2 H-N1 分道谓词：recent = end >= cutoff（默认选项左闭）；history = end < cutoff
    /// （.strictEndDate 右开）。两道互补覆盖全部样本，边界样本恰出现一次。墓碑不携日期，
    /// HealthKit 可能在两道都回报同一 UUID——commit 幂等（首道删索引后第二道成为
    /// 「纯删除且无窗口受影响」空页，安全排空）。边界语义与 Domain `HealthFetchScope.matches`
    /// 一致，由 HealthKitReaderPredicateTests 在 CI 实证。
    static func changePredicate(for scope: HealthFetchScope) -> NSPredicate {
        switch scope.lane {
        case .recent:
            return HKQuery.predicateForSamples(withStart: scope.cutoff, end: nil, options: [])
        case .history:
            return HKQuery.predicateForSamples(withStart: nil, end: scope.cutoff, options: [.strictEndDate])
        }
    }

    static func stepStatisticsPredicate(for window: HealthImportWindow, sampleIDs: Set<UUID>) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: []),
            HKQuery.predicateForObjects(with: sampleIDs)
        ])
    }

    private static func reference(_ sample: HKSample, kind: HealthDataKind) throws -> HealthSampleReference {
        let ref = HealthSampleReference(id: sample.uuid, kind: kind, sourceID: sample.sourceRevision.source.bundleIdentifier,
                                       start: sample.startDate, end: sample.endDate)
        guard ref.isValid else { throw ReaderError.incompleteSnapshot }
        return ref
    }
}
#endif
