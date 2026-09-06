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
        } catch {
            logger.error("设置加载失败: \(error)")
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
            let careModeOn = (values[.careModeEnable] ?? AppSettingKey.careModeEnable.defaultValue) == "true"
            guard ReadbackPolicy.isSelectable(pref, careMode: careModeOn) else {
                logger.info("非法回读组合被拒：\(value)（careMode=\(careModeOn)）")
                return
            }
        }
        do {
            try await store.set(value, for: key)
            values[key] = value
            // 审查修复（分裂脑）：readbackPreference 与 careMode 的运行时真源
            // 在 UserDefaults（AppState 读），DB 写而镜像不写 = 设置无效；
            // restoreDefaults 亦需同步清镜像（幂等双写）
            if key == .readBackOptIn || key == .careModeEnable {
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
            // 评审修正（sweep）：语言有第二事实源（L10n.languageCache + vl.language
            // 镜像）——恢复默认后 UI 显示简体选中、文案却停留在旧语言直到重启。
            // 同步重置语言缓存/镜像并广播（setLanguage 相等性守卫保证幂等）
            L10n.setLanguage(AppSettingKey.language.defaultValue)
            await load()
        } catch {
            logger.error("恢复默认失败: \(error)")
        }
    }

    func loadAudit() async {
        do {
            auditEntries = try await store.auditEntries().map { AuditEntry($0) }
        } catch {
            logger.error("审计加载失败: \(error)")
        }
    }
}
