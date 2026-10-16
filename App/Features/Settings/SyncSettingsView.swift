import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols
import Perception

/// FR13.12 多设备同步状态仓（批次 2 切片 C）：
/// 开关（订阅门槛 hasBackupSyncShare，BR-010 即时生效）→ 立即同步（手动 push）
/// → 候选计数（fetchAccepted 预选结果）。**合并本身归 ADR-019 流程**
/// ——逐候选走既有备份恢复管线（影响清单+冲突三列），本仓不自行导入。
@MainActor
@Perceptible
final class SyncState {
    enum Phase: Equatable { case idle, pushing, refreshing }
    private(set) var phase: Phase = .idle
    private(set) var candidateCount = 0
    private(set) var degradedMessage: String?

    private let service: SyncService
    private let settings: AppSettingsStore
    private let realmProvider: @MainActor () -> UUID?
    private let logger = Logger(subsystem: "com.vitaliber", category: "sync")

    init(service: SyncService, settings: AppSettingsStore, realmProvider: @escaping @MainActor () -> UUID?) {
        self.service = service
        self.settings = settings
        self.realmProvider = realmProvider
    }

    var enabled: Bool { settings.values[.syncEnabled] == "true" }

    var lastSyncAt: Date? {
        guard let raw = settings.values[.syncLastSyncAt], let ts = Double(raw), ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    func setEnabled(_ on: Bool) {
        Task { await settings.set(on ? "true" : "false", for: .syncEnabled) }
        // H6 裁决（design V1.7 §10.1 C3）：关闭 = 立即停止读写 + 保留云端信封
        // （数据仍在用户的 iCloud，可经文件 App 删除——两动作均写审计的接线归 App 层）
    }

    private func deviceIdentity() async -> (deviceId: UUID, seq: UInt64) {
        let existing = settings.values[.syncDeviceId] ?? ""
        let deviceId = UUID(uuidString: existing) ?? UUID()
        if UUID(uuidString: existing) == nil {
            await settings.set(deviceId.uuidString, for: .syncDeviceId)
        }
        let seq = UInt64(settings.values[.syncSeq] ?? "0") ?? 0
        return (deviceId, seq)
    }

    /// 手动[立即同步]（默认触发形态；自动同步为显式开启的可选项，P1 不默认）
    func syncNow() async {
        guard let realmId = realmProvider() else {
            degradedMessage = L10n.syncUnavailableNoRealm
            return
        }
        phase = .pushing
        degradedMessage = nil
        do {
            let (deviceId, seq) = await deviceIdentity()
            try await service.push(realmId: realmId, deviceId: deviceId, seq: seq + 1)
            await settings.set("\(seq + 1)", for: .syncSeq)
            await settings.set("\(Date().timeIntervalSince1970)", for: .syncLastSyncAt)
        } catch {
            logger.error("同步推送失败: \(error)")
            degradedMessage = L10n.syncPushFailed
        }
        phase = .idle
    }

    func refreshCandidates() async {
        guard enabled, let realmId = realmProvider() else { return }
        phase = .refreshing
        do {
            candidateCount = try await service.fetchAccepted(realm: realmId).count
            degradedMessage = nil
        } catch {
            logger.error("候选拉取失败: \(error)")
            degradedMessage = L10n.syncPullFailed
        }
        phase = .idle
    }
}

/// 同步设置页（SP 新，单视图共享 iPhone/iPad，禁平行视图 ADR-021）
struct SyncSettingsView: View {
    @Environment(SyncState.self) private var state
    @Environment(AppEntitlementStore.self) private var entitlements

    var body: some View {
        WithPerceptionTracking {
            List {
                Section {
                    Toggle(L10n.syncEnable, isOn: Binding(
                        get: { state.enabled },
                        set: { on in
                            // 订阅门槛（comercial V1.12）：同步本体订阅——未解锁弹墙并保持关闭
                            guard entitlements.owned.contains(.proBase) else {
                                _ = entitlements.evaluateTrigger(.syncFirstToggle)
                                return
                            }
                            state.setEnabled(on)
                            if on { Task { await state.refreshCandidates() } }
                        }
                    ))
                    .accessibilityIdentifier("SP-sync.enable")
                } footer: {
                    Text(L10n.syncEnableNote)
                        .font(.caption2)
                }
                if state.enabled {
                    Section {
                        Button {
                            Task { await state.syncNow() }
                        } label: {
                            if case .pushing = state.phase {
                                HStack { ProgressView(); Text(L10n.syncPushing) }
                            } else {
                                Label(L10n.syncNow, systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(state.phase != .idle)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("SP-sync.now")
                        if let last = state.lastSyncAt {
                            Text(L10n.syncLastSync(last.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(L10n.syncCandidates(state.candidateCount))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-sync.candidates")
                        Button(L10n.syncRefreshCandidates) {
                            Task { await state.refreshCandidates() }
                        }
                        .disabled(state.phase != .idle)
                        .frame(minHeight: 44)
                    } footer: {
                        Text(L10n.syncScopeNote)
                            .font(.caption2)
                    }
                }
                if let message = state.degradedMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .accessibilityIdentifier("SP-sync.degraded")
                }
            }
            .scrollContentBackground(.hidden)
            .tintedCanvas()
            .navigationTitle(L10n.syncTitle)
        }
    }
}
