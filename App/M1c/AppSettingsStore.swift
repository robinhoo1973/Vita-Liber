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

    init(store: SettingsStore) { self.store = store }

    func load() async {
        do {
            var map: [AppSettingKey: String] = [:]
            for key in AppSettingKey.allCases {
                map[key] = try await store.value(for: key)
            }
            values = map
        } catch {
            logger.error("设置加载失败: \(error)")
        }
    }

    func set(_ value: String, for key: AppSettingKey) async {
        do {
            try await store.set(value, for: key)
            values[key] = value
        } catch {
            logger.error("设置写入失败: \(error)")
        }
    }

    func restoreDefaults() async {
        do {
            try await store.restoreDefaults()
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
