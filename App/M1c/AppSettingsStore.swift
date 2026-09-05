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
