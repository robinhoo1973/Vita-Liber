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
        do {
            // 审查修复：一次批量查询替代逐键 SELECT（~35 次串行 actor 往返）
            values = try await store.allValues()
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
            guard let stored = values[key], stored != key.defaultValue else { continue }
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
        do {
            try await store.set(value, for: key)
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
            // FR14.1/FR14.2 授权变更写审计（grant_change——撤回即时生效且审计可见）
            if key.rawValue.hasPrefix("auth") {
                try await audit?.record(action: "grant_change", entityType: "setting",
                                        entityId: key.rawValue, actorLocal: "owner",
                                        meta: "value=\(value)")
            }
        } catch {
            logger.error("设置写入失败: \(error)")
        }
    }

    func restoreDefaults() async {
        do {
            try await store.restoreDefaults()
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

    /// 通知投递门/willPresent 消费的 UserDefaults 镜像键集合（第七轮修复）
    static let mirroredKeys: [AppSettingKey] = [
        .remindChannelMeds, .remindChannelApts, .remindChannelExam,
        .remindChannelExpiry, .remindChannelAlert, .remindChannelBackup,
        .inAppBannerEnabled,
    ]

    func loadAudit() async {
        do {
            auditEntries = try await store.auditEntries().map { AuditEntry($0) }
        } catch {
            logger.error("审计加载失败: \(error)")
        }
    }
}
