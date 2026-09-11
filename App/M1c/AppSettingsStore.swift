import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols

/// F14 设置状态仓（@Observable）：桥接 Infrastructure 的 SettingsStore actor。
@MainActor
@Observable
final class AppSettingsStore {
    private(set) var values: [AppSettingKey: String] = [:]
    private(set) var authAIRevision: UInt64 = 0
    private var mutationRevision: UInt64 = 0
    private var authorizationWrites = 0
    private var authorizationWriteTask: Task<Void, Error>?
    private var deniedAIUntilGrant = false
    private(set) var auditEntries: [AuditEntry] = []
    private let store: SettingsStore
    /// FR14.2 授权变更审计（可选注入；关闭即停后续处理，审计可见）
    private let audit: AuditLogWriter?
    private let logger = Logger(subsystem: "com.vitaliber", category: "settings")

    struct AuditEntry: Identifiable, Equatable {
        let id = UUID()
        var action: String
        var entityType: String
        var at: Date
        init(_ e: Infrastructure.SettingsStore.AuditEntry) {
            self.action = e.action; self.entityType = e.entityType; self.at = e.at
        }
    }

    init(store: SettingsStore, audit: AuditLogWriter? = nil) {
        self.store = store
        self.audit = audit
    }

    func load() async {
        guard authorizationWrites == 0 else { return }
        let revision = mutationRevision
        do {
            // 审查修复：一次批量查询替代逐键 SELECT（~35 次串行 actor 往返）
            var loaded = try await store.allValues()
            guard revision == mutationRevision, authorizationWrites == 0 else { return }
            if deniedAIUntilGrant { loaded[.authAI] = "false" }
            if SettingsRules.resolved(values[.authAI], key: .authAI) != SettingsRules.resolved(loaded[.authAI], key: .authAI) {
                authAIRevision &+= 1
            }
            values = loaded
            seedMirrorsIfNeeded()
        } catch {
            logger.error("设置加载失败: \(error)")
        }
    }

    /// 第八轮全仓审查修复（升级分裂脑）：UserDefaults 镜像只在 set()/
    /// restoreDefaults() 写入——旧版本已落库的偏好（DB 有值、镜像无值）
    /// 升级后投递门/willPresent/关怀模式读到 nil 即回落默认（锁屏照常响铃、
    /// 横幅复活、关怀版式关闭而开关显示开）。load() 后一次性补齐：镜像缺项
    /// 即回填 DB 值；等于缺省值不写（保持 nil=默认语义）；只补不覆盖（幂等）。
    private func seedMirrorsIfNeeded() {
        let defaults = UserDefaults.standard
        for key in Self.mirroredKeys {
            guard defaults.object(forKey: key.rawValue) == nil else { continue }
            // values 来自 allValues()（逐键默认值解析，恒有值）——`values[key]`
            // 的 nil 分支为不可达死代码，显式以 defaultValue 兜底并注明。
            let stored = values[key] ?? key.defaultValue
            guard stored != key.defaultValue else { continue }
            defaults.set(stored, forKey: key.rawValue)
        }
        // 关怀模式镜像必须写 Bool（AppState.careMode/careModeTruth 以
        // bool(forKey:) 读；String "true" 在 Apple 平台恒读 false）
        if defaults.object(forKey: AppSettingKey.careModeEnable.rawValue) == nil,
           let stored = values[.careModeEnable],
           stored != AppSettingKey.careModeEnable.defaultValue {
            defaults.set(stored == "true", forKey: AppSettingKey.careModeEnable.rawValue)
        }
        // 回读偏好镜像（AppState.readbackPreference 同键读取）
        if defaults.object(forKey: AppSettingKey.readBackOptIn.rawValue) == nil,
           let stored = values[.readBackOptIn],
           stored != AppSettingKey.readBackOptIn.defaultValue {
            defaults.set(stored, forKey: AppSettingKey.readBackOptIn.rawValue)
        }
    }

    func set(_ value: String, for key: AppSettingKey) async {
        // 第六轮全仓审查修复：非法组合（alwaysInCareMode 而关怀模式关闭）
        // 必须在写入入口拦截——原校验只存在于 PreferencesView.save 与
        // AppState.readbackPreference 两个调用点，任何直接 set() 路径
        // （恢复/未来 UI/测试）都能把非法值写进 UserDefaults 镜像并被
        // AppState 原样读回（「非法组合不落盘」的不变量应守在写入口）
        if key == .readBackOptIn {
            let pref = ReadbackPreference(rawValue: value) ?? .never
            // 第七轮全仓审查修复：判定必须读 UserDefaults 运行时真源（与
            // AppState.careMode 同源）——DB 镜像 values[.careModeEnable] 只在
            // 经本 store 写时更新；经 CareModeSettingsView（只写 app.careMode，
            // 即 UserDefaults）开关怀模式时镜像恒 nil→"false"，合法的「总是」
            // 被静默拒绝且 UI 仍显示已选（假宣告）
            guard ReadbackPolicy.isSelectable(pref, careMode: Self.careModeTruth) else {
                logger.info("非法回读组合被拒：\(value)（careMode=\(Self.careModeTruth)）")
                return
            }
        }
        mutationRevision &+= 1
        if key == .authAI {
            // Revoke before suspension; grants become visible only after persistence succeeds.
            authAIRevision &+= 1
            authorizationWrites += 1
            if value == "false" {
                deniedAIUntilGrant = true
                values[key] = "false"
            }
        }
        defer { if key == .authAI { authorizationWrites -= 1 } }
        let authorizationRevision = authAIRevision
        do {
            if key == .authAI {
                let preceding = authorizationWriteTask
                let store = self.store
                let work = Task {
                    if let preceding { do { try await preceding.value } catch { /* A later intent may retry. */ } }
                    try await store.set(value, for: key)
                }
                authorizationWriteTask = work
                try await work.value
            } else {
                try await store.set(value, for: key)
            }
            // 审查修复（审计先行）：授权变更在被更新的写入超越时仍已
            // 持久化——审计必须记录已发生的变更事实，不得随代际守卫一并
            // 跳过（撤回→立即重授两连点：撤回落库但无审计行，FR14.2
            // 授权证据链断裂）
            if key.rawValue.hasPrefix("auth") {
                try await audit?.record(action: "grant_change", entityType: "setting",
                                        entityId: key.rawValue, actorLocal: "owner",
                                        meta: "value=\(value)")
            }
            if key == .authAI, authorizationRevision != authAIRevision { return }
            if key == .authAI, value == "true" { deniedAIUntilGrant = false }
            // 第七轮全仓审查修复（TOCTOU）：await 期间 MainActor 可重入，
            // 关怀模式可能在写入间隙被切走——写入后按运行时真源复核，
            // 非法则回滚为默认值（默认 ask 恒可设），保证「非法组合不落盘」
            if key == .readBackOptIn {
                let pref = ReadbackPreference(rawValue: value) ?? .never
                guard ReadbackPolicy.isSelectable(pref, careMode: Self.careModeTruth) else {
                    logger.info("回读组合竞态回滚：\(value)（关怀模式已切换）")
                    try? await store.set(AppSettingKey.readBackOptIn.defaultValue, for: key)   // try?-ok: 回滚失败只记日志，下次写入前复核仍会拦截
                    values[key] = AppSettingKey.readBackOptIn.defaultValue
                    UserDefaults.standard.set(AppSettingKey.readBackOptIn.defaultValue,
                                              forKey: key.rawValue)
                    return
                }
            }
            values[key] = value
            // 审查修复（分裂脑）：readbackPreference 与 careMode 的运行时真源
            // 在 UserDefaults（AppState 读），DB 写而镜像不写 = 设置无效；
            // restoreDefaults 亦需同步清镜像（幂等双写）
            // 第八轮修复（类型分裂脑）：careModeEnable 镜像此前写 String
            // "true"/"false"，而全部读取方（AppState.careMode/careModeTruth）
            // 用 bool(forKey:)——Apple 平台 NSString 恒读 false，开关显示开而
            // 关怀版式实际关闭。镜像改写 Bool（与 CareModeSettingsView 的
            // app.careMode 写入同型）。
            if key == .readBackOptIn {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            }
            if key == .careModeEnable {
                UserDefaults.standard.set(value == "true", forKey: key.rawValue)
            }
            // 第七轮全仓审查修复（FR9.18 通道偏好接线）：remindChannel* 与
            // inAppBannerEnabled 镜像 UserDefaults——通知投递门（ChannelGated
            // Scheduler）与 willPresent 在非主线程读该镜像（UserDefaults 线程
            // 安全），无需 @MainActor 往返
            if key.rawValue.hasPrefix("remindChannel") || key == .inAppBannerEnabled {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            }
            // 审查修复（冻结键镜像缺失）：TTS rateProvider 与识别引擎工厂
            // （EngineFactories.choiceProvider）以 UserDefaults 冻结键为运行时真源，
            // 而 set() 此前只镜像 readBackOptIn/careModeEnable/remindChannel*——
            // voiceEngine/speechRate 只落 DB 与内存 values，镜像恒 nil，工厂
            // 永远读到默认档/默认语速（用户选择从未生效，语音实验室 A/B 对照
            // 失真）。此处补镜像写；restoreDefaults 经 mirroredKeys 幂等清镜像。
            if key == .voiceEngine || key == .speechRate {
                UserDefaults.standard.set(value, forKey: key.rawValue)
            }
        } catch {
            logger.error("设置写入失败: \(error)")
        }
    }

    func restoreDefaults() async {
        mutationRevision &+= 1
        authAIRevision &+= 1
        deniedAIUntilGrant = true
        values[.authAI] = "false"
        authorizationWrites += 1
        let authorizationRevision = authAIRevision
        let preceding = authorizationWriteTask
        let store = self.store
        let work = Task {
            if let preceding { do { try await preceding.value } catch { /* Restore explicitly replaces previous settings. */ } }
            try await store.restoreDefaults()
        }
        authorizationWriteTask = work
        do {
            try await work.value
            authorizationWrites -= 1
            // 审查修复：被更新的 authAI 写入超越时不得跳过镜像清理——DB
            // 重置已在串行链中提交，镜像/语言/缓存不清理则 careMode 等
            // 运行时真源与「已恢复默认」的 DB 分裂（第八轮修复的反面）。
            // 仅授权撤销态位（deniedAIUntilGrant）让位给最新写入。
            if authorizationRevision == authAIRevision {
                deniedAIUntilGrant = false
            }
            // 审查修复：运行时镜像同步重置——原只清 DB，careMode 仍为 true
            // 而开关显示关闭（首页仍是关怀版式，设置页却关着）
            UserDefaults.standard.removeObject(forKey: AppSettingKey.readBackOptIn.rawValue)
            UserDefaults.standard.removeObject(forKey: AppSettingKey.careModeEnable.rawValue)
            // 第七轮修复（FR9.18 通道偏好）：通道镜像与横幅开关镜像一并重置
            for key in Self.mirroredKeys {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
            // 评审修正（sweep）：语言有第二事实源（L10n.languageCache + vl.language
            // 镜像）——恢复默认后 UI 显示简体选中、文案却停留在旧语言直到重启。
            // 同步重置语言缓存/镜像并广播（setLanguage 相等性守卫保证幂等）
            L10n.setLanguage(AppSettingKey.language.defaultValue)
            await load()
        } catch {
            authorizationWrites -= 1
            logger.error("恢复默认失败: \(error)")
        }
    }

    /// 第七轮全仓审查修复：关怀模式运行时真源 = UserDefaults（与 AppState.careMode
    /// 完全同源同键，含旧键 "careMode" 只读兼容）——写前判定的唯一权威。
    private static var careModeTruth: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppSettingKey.careModeEnable.rawValue) != nil {
            return defaults.bool(forKey: AppSettingKey.careModeEnable.rawValue)
        }
        return defaults.bool(forKey: "careMode")
    }

    /// 通知投递门/willPresent 消费的 UserDefaults 镜像键集合（第七轮修复）。
    /// 审查修复（镜像不对称）：全局 .remindChannel 此前不在集合内——set() 的
    /// 前缀镜像（"remindChannel" 前缀含全局键）会写它，但 seedMirrorsIfNeeded
    /// 不补种（升级后 DB 已存的全局通道偏好被投递门的 `?? default` 回落吞掉）、
    /// restoreDefaults 不复位（恢复默认后全局通道镜像残留旧值）——写入路径
    /// 与复位/补种路径不对称。全局键是 String 形态，泛型循环直接适用。
    static let mirroredKeys: [AppSettingKey] = [
        .remindChannel,
        .remindChannelMeds, .remindChannelApts, .remindChannelExam,
        .remindChannelExpiry, .remindChannelAlert, .remindChannelBackup,
        .inAppBannerEnabled,
        // 冻结键消费者（EngineFactories 的 TTS rateProvider 与识别引擎
        // choiceProvider）以 UserDefaults 为运行时真源：升级回填
        // （seedMirrorsIfNeeded）与恢复默认清镜像（restoreDefaults）都必须覆盖。
        .voiceEngine, .speechRate,
    ]

    func loadAudit() async {
        do {
            auditEntries = try await store.auditEntries().map { AuditEntry($0) }
        } catch {
            logger.error("审计加载失败: \(error)")
        }
    }
}
