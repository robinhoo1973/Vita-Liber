#if os(iOS)
import Foundation
import BackgroundTasks
import HealthKit
import Domain
import Protocols

/// FR16.1 自动化后台同步 + 前台增量兜底（V3.86，health-import 阶段1–3）：
/// HKObserverQuery + enableBackgroundDelivery(.hourly) + BGAppRefreshTask
/// （"com.vitaliber.healthkit-sync"）+ 前台 HKAnchoredObjectQuery 增量兜底，
/// 杜绝仅靠手动点击。锚点持久化落 DB（`hk_sync_anchor`，随 .vlbu 备份往返——
/// UserDefaults 不入备份、恢复后锚点丢失=漏读/重放，已否决）。
///
/// 评估与入库双流（FR7.9）：分钟级原始读数内存态评估（AlertRuleEngine →
/// alert_event，保 FR16.2 连续/持续语义）→ 小时窗口聚合（reader.deviceRows）
/// → metric_sample（与手输同一写门，幂等键含来源）。
///
/// 纪律：
/// - BGTask 标识符须登记 Info.plist `BGTaskSchedulerPermittedIdentifiers`；
///   `task as!` 强制转换撞 L0 [1] 门禁——一律 `guard let as?`；
/// - 后台执行受系统调度约束——承诺口径「尽力每小时 + 手动同步 + 前台兜底」
///   （FR16.1 V3.49 同步时间沟通契约），不得承诺实时；
/// - HKHealthStore 非 Sendable：本 actor 持有，对外只发 Sendable 值对象。
public actor HealthKitSyncService {
    public static let bgTaskIdentifier = "com.vitaliber.healthkit-sync"

    public struct SyncReport: Sendable, Equatable {
        /// L1+ 预警送达数（评估流）
        public var elevated: Int
        /// 范围不可用计数（FR16.4 诚实呈现）
        public var noRangeCount: Int
        /// 落库行数（入库流）
        public var persistedRows: Int
        public var lastSyncAt: Date
        public init(elevated: Int, noRangeCount: Int, persistedRows: Int, lastSyncAt: Date) {
            self.elevated = elevated
            self.noRangeCount = noRangeCount
            self.persistedRows = persistedRows
            self.lastSyncAt = lastSyncAt
        }
    }

    private let reader: HealthKitReader
    /// 与 reader 共享的 HKHealthStore 单实例（AppContainer 装配时注入同源——
    /// Apple 文档纪律：一个进程一个 HKHealthStore）
    private let healthStore: HKHealthStore
    private let trends: TrendQueryStore
    private let guidelines: GuidelineStore
    private let scheduler: any ReminderScheduling
    private let writer: any DatabaseWriter
    /// 24h 去重键（会话级；跨重启去重由 delivered 守卫 + 稳定 event.id 承担）
    private var lastAlertKey: [String: Date] = [:]
    private var observers: [HKObserverQuery] = []

    public init(reader: HealthKitReader, healthStore: HKHealthStore,
                trends: TrendQueryStore, guidelines: GuidelineStore,
                scheduler: any ReminderScheduling, writer: any DatabaseWriter) {
        self.reader = reader
        self.healthStore = healthStore
        self.trends = trends
        self.guidelines = guidelines
        self.scheduler = scheduler
        self.writer = writer
    }

    // MARK: - 后台观察（App init 调用；幂等）

    /// 注册 HKObserverQuery + hourly 后台投递。observer 回调不能执行重活——
    /// 按业界标准姿势调度 BGAppRefreshTaskRequest，由系统择机唤起执行。
    public func startBackgroundObservation() {
        guard observers.isEmpty else { return }
        for type in HealthKitReader.readTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                completion()
                Task { await self?.scheduleBackgroundRefresh() }
            }
            healthStore.execute(query)
            observers.append(query)
        }
        enableBackgroundDelivery()
    }

    /// BGTaskScheduler 注册（VitaLiberApp.init 调用）。
    /// launchHandler 在后台唤起时执行：完成后必须 setTaskCompleted——
    /// 过期不报会被系统标记为不健康任务、降低后续调度频次。
    public nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task {
                // 后台唤起路径经服务实例执行（App 装配期注入）
                let success = await Self.backgroundSyncHandler?()
                refresh.setTaskCompleted(success: success)
            }
        }
    }

    /// 后台唤起执行体（App 装配时注入——闭包捕获 App 层服务实例/设置值；
    /// 注册是静态入口，执行经此单一闭包）
    nonisolated(unsafe) public static var backgroundSyncHandler: (@Sendable () async -> Bool)?

    // MARK: - 同步主流程（手动/前台/后台三路径共用）

    /// 授权状态（双门控：设置开关在 App 层检查，此处只查系统授权）
    public func isAuthorized() async -> Bool {
        await reader.authorizationStatus() == .sharingAuthorized
    }

    /// 前台锚点增量判断：任一类型自上次锚点以来有新样本即返回 true。
    /// 首跑（无锚）恒 true（全量初始化，防洪流：首跑只聚合近 24h 窗口）。
    public func hasNewData() async -> Bool {
        for type in HealthKitReader.readTypes {
            guard let anchor = await loadAnchor(key: anchorKey(type)) else { return true }
            if let changes = try? await reader.anchoredChanges(type: type, anchor: anchor),   // try?-ok: 单类型锚点探测失败按「有新数据」继续，绝不因探测失败跳过同步
               !changes.added.isEmpty {
                return true
            }
        }
        return false
    }

    /// 执行一次完整同步：评估（分钟级内存态）+ 入库（小时聚合）双流。
    public func performSync(patientId: UUID, quietStart: String, quietEnd: String,
                            hours: Int = 24) async throws -> SyncReport {
        let now = Date()
        let readings = try await reader.recentReadings(within: hours, now: now)
        // 评估流：分钟级原始读数 → evaluateAndRecord → L1+ 通知
        let delivered = try await scheduler.delivered()
        var elevated = 0
        var noRange = 0
        for reading in readings {
            do {
                let event = try await guidelines.evaluateAndRecord(
                    reading: reading, patientId: patientId, ruleId: "f16.healthkit")
                guard event.severity != .L0 else { continue }
                let key = "\(patientId.uuidString)-\(reading.metricKey)-\(event.severity.rawValue)"
                if let last = lastAlertKey[key],
                   now < DayArithmetic.offset(days: 1, from: last) { continue }
                let alertId = "alert-\(event.id.uuidString)"
                guard !delivered.contains(alertId) else { continue }
                if event.severity == .L1 && Self.isQuietHours(start: quietStart, end: quietEnd, now: now) {
                    continue
                }
                try await scheduler.schedule(dose: alertId, at: now.addingTimeInterval(5),
                                             route: .alertHistory)
                lastAlertKey[key] = now
                elevated += 1
            } catch GuidelineStore.StoreError.noApplicableRange {
                noRange += 1
            } catch {
                continue
            }
        }
        // 入库流：小时窗口聚合行 → metric_sample（幂等键含来源）
        let rows = try await reader.deviceRows(within: hours, now: now)
        let persisted = try await trends.addDeviceSamples(patientId: patientId, rows: rows)
        // 锚点推进（逐类型；失败不阻断主流程——下次同步重查增量）
        for type in HealthKitReader.readTypes {
            if let changes = try? await reader.anchoredChanges(type: type,   // try?-ok: 锚点推进失败下次同步按旧锚重查增量，不阻断主流程
                                                               anchor: await loadAnchor(key: anchorKey(type))) {
                if let newAnchor = changes.anchor {
                    await saveAnchor(key: anchorKey(type), anchor: newAnchor)
                }
            }
        }
        return SyncReport(elevated: elevated, noRangeCount: noRange,
                          persistedRows: persisted, lastSyncAt: now)
    }

    // MARK: - 后台调度与锚点持久化

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)   // try?-ok: 调度失败（系统忙）不阻断观察回调，前台兜底路径仍可用
    }

    private func enableBackgroundDelivery() {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }
        try? healthStore.enableBackgroundDelivery(for: hrType,   // try?-ok: 投递注册失败回落手动/前台路径，不阻断
                                                  frequency: .hourly)
    }

    /// 锚点 key：`hk.{typeIdentifier}`（patient 维度不参与——HealthKit 为设备级）
    private func anchorKey(_ type: HKObjectType) -> String {
        "hk.\(type.identifier)"
    }

    private func loadAnchor(key: String) async -> HKQueryAnchor? {
        guard let row = try? await writer.read({ db in   // try?-ok: 锚点读失败按「无锚全量」处理，绝不阻断同步
            try Row.fetchOne(db, sql: "SELECT anchor_value FROM hk_sync_anchor WHERE anchor_key = ?",
                             arguments: [key])
        }), let encoded = row["anchor_value"] as String?,
              let data = Data(base64Encoded: encoded) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)   // try?-ok: 锚点解码失败按「无锚全量」处理，绝不阻断同步
    }

    private func saveAnchor(key: String, anchor: HKQueryAnchor) async {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)   // try?-ok: 锚点序列化失败下次按全量重查，不阻断
        guard let data else { return }
        let encoded = data.base64EncodedString()
        try? await writer.write { db in   // try?-ok: 锚点写失败下次按旧锚重查增量，不阻断
            try db.execute(sql: """
                INSERT INTO hk_sync_anchor (anchor_key, anchor_value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(anchor_key) DO UPDATE SET anchor_value = excluded.anchor_value,
                                                       updated_at = excluded.updated_at
                """, arguments: [key, encoded, Date().timeIntervalSince1970])
        }
    }

    /// 安静时段判定（跨午夜区间；start==end 非法窗口按失败开放——绝不静默吞预警）
    static func isQuietHours(start: String, end: String, now: Date = Date()) -> Bool {
        guard let s = hourOf(start), let e = hourOf(end), s != e else { return false }
        let hour = Calendar.current.component(.hour, from: now)
        return s < e ? (hour >= s && hour < e) : (hour >= s || hour < e)
    }

    private static func hourOf(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h
    }
}
#endif
