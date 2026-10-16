import Foundation
import SwiftUI
import os
import Domain
import Infrastructure
import Protocols
import Perception

/// FR13.12 多设备同步状态仓（批次 2 切片 C）：
/// 开关（订阅门槛 gateProBase(.syncFirstToggle)，BR-010 即时生效）→ 立即同步（手动 push）
/// → 候选计数（fetchAccepted 预选结果）。**合并本身归 ADR-019 流程**
/// ——逐候选走既有备份恢复管线（影响清单+冲突三列），本仓不自行导入。
@MainActor
@Perceptible
final class SyncState {
    enum Phase: Equatable { case idle, pushing, refreshing }
    private(set) var phase: Phase = .idle
    private(set) var candidates: [SyncEnvelopeCandidate] = []
    private(set) var degradedMessage: String?
    /// 首次同步 push 触发主密钥注册时的一次性恢复码（码原文零存储——展示即最后机会；
    /// 评审修复：push 返回值此前被丢弃，恢复码从未面世，与备份链路同款展示卡片）
    private(set) var pendingRecoveryCode: String?

    private let service: SyncService
    private let settings: AppSettingsStore
    private let realmProvider: @MainActor () -> UUID?
    private let logger = Logger(subsystem: "com.vitaliber", category: "sync")
    /// 设备身份缓存（评审修复，写-读竞态）：首调生成 UUID 并写盘前，并发调用会各自生成
    /// 不同身份——先入缓存再等待落盘，进程内身份单点。
    private var deviceIdCache: UUID?

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

    /// 评审修复（写读竞态）：此前 fire-and-forget Task 写设置后立即返回——调用方随即
    /// refreshCandidates，其 `guard enabled` 读到尚未落盘的旧值 false，候选区不刷新。
    /// 改为 async：写入完成后调用方再刷新。
    func setEnabled(_ on: Bool) async {
        await settings.set(on ? "true" : "false", for: .syncEnabled)
        // H6 裁决（design V1.7 §10.1 C3）：关闭 = 立即停止读写 + 保留云端信封
        // （数据仍在用户的 iCloud，可经文件 App 删除——两动作均写审计的接线归 App 层）
    }

    private func deviceIdentity() async -> (deviceId: UUID, seq: UInt64) {
        let existing = settings.values[.syncDeviceId] ?? ""
        let parsed = UUID(uuidString: existing)
        let deviceId: UUID
        if let parsed {
            deviceId = parsed
        } else if let cached = deviceIdCache {
            // 并发首调（syncNow 与 refreshCandidates 同拍）此前各自生成 UUID——
            // 先入缓存的写-读竞态（评审修复）：候选过滤/seq 归并围绕两个身份分裂。
            deviceId = cached
        } else {
            deviceId = UUID()
            deviceIdCache = deviceId   // 先入缓存再落盘：等待写盘期间再次调用同 id
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
            let package = try await service.push(realmId: realmId, deviceId: deviceId, seq: seq + 1)
            await settings.set("\(seq + 1)", for: .syncSeq)
            await settings.set("\(Date().timeIntervalSince1970)", for: .syncLastSyncAt)
            if let code = package.recoveryCode {
                // 一次性恢复码（码原文零存储）：展示即最后机会，确认后清除
                pendingRecoveryCode = code
                _ = await service.takeUnseenRecoveryCode()   // 同一码已在手——排空暂存防日后回弹
            } else if let stillborn = await service.takeUnseenRecoveryCode() {
                // 上轮 push 半程失败（createBackup 内/commit 失败）的码：主密钥已注册、
                // 重试恒 nil 码——此处不展示即永久丢失（评审修复，零知识链断头）
                pendingRecoveryCode = stillborn
            }
        } catch {
            logger.error("同步推送失败: \(error)")
            // 评审修复（恢复码链断点）：push 失败路径取回未面世的一次性码——
            // createBackup 可能已生成码并持久化包裹段（媒体载具/密封/commit 后半程错误）
            if let code = await service.takeUnseenRecoveryCode() {
                pendingRecoveryCode = code
            }
            degradedMessage = L10n.syncPushFailed
        }
        phase = .idle
    }

    /// 恢复码已保存确认（展示卡片收起）
    func confirmRecoveryCodeSaved() {
        pendingRecoveryCode = nil
    }

    func refreshCandidates() async {
        guard enabled, let realmId = realmProvider() else { return }
        phase = .refreshing
        do {
            // 评审修复（自合并）：fetchAccepted 的「同 deviceId 取 max seq」会把本机
            // 最近一次 push 的信封也列为候选——UI 逐候选走 ADR-019 等于把自身快照
            // 合并进自身（数据未动时是空冲突流程；本地有未推改动时逼用户与自己的
            // 历史三选一；误选 coexist 则全库数据以新 id 重复一份）。候选语义 =
            // 「他人快照」，本机信封排除。
            let (myDeviceId, _) = await deviceIdentity()
            candidates = try await service.fetchAccepted(realm: realmId)
                .filter { $0.deviceId != myDeviceId }
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
    @Environment(BackupState.self) private var backupState
    @State private var openMerge = false

    var body: some View {
        WithPerceptionTracking {
            List {
                Section {
                    Toggle(L10n.syncEnable, isOn: Binding(
                        get: { state.enabled },
                        set: { on in
                            // 订阅门槛（comercial V1.12）：同步本体订阅——未解锁弹墙并保持关闭。
                            // 仅拦「开启」方向（评审修复）：此前双向拦截——订阅态异常
                            //（恢复导入/权益读取故障）时已开用户连关闭都点不动，隐私开关卡死。
                            if on {
                                guard entitlements.gateProBase(.syncFirstToggle) else { return }
                            }
                            Task {
                                // 评审修复（写读竞态）：等设置落盘再刷新候选——此前
                                // fire-and-forget 写 + 立即刷新，refreshCandidates 的
                                // guard enabled 读到旧值 false，候选区静默不刷新
                                await state.setEnabled(on)
                                if on { await state.refreshCandidates() }
                            }
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
                        Text(L10n.syncCandidates(state.candidates.count))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("SP-sync.candidates")
                        Button(L10n.syncRefreshCandidates) {
                            Task { await state.refreshCandidates() }
                        }
                        .disabled(state.phase != .idle)
                        .frame(minHeight: 44)
                        // 候选合并（切片 D）：逐信封走既有恢复管线（影响清单+冲突三选一），绝不静默覆盖
                        ForEach(Array(state.candidates.enumerated()), id: \.offset) { index, candidate in
                            Button {
                                Task {
                                    await backupState.analyzeSyncCandidate(candidate.data)
                                    openMerge = true
                                }
                            } label: {
                                Label(L10n.syncCandidateDevice(candidate.deviceId.uuidString, candidate.seq),
                                      systemImage: "arrow.down.circle")
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("SP-sync.candidate.\(index)")
                        }
                    } footer: {
                        Text(L10n.syncScopeNote)
                            .font(.caption2)
                    }
                }
                if let code = state.pendingRecoveryCode {
                    // 首次同步 push 注册主密钥 → 恢复码一次性展示（与备份链路同款卡片；
                    // 零知识：码原文零存储，展示即最后机会）
                    Section {
                        Label(L10n.backupRecoveryCodeTitle, systemImage: "key.fill")
                        Text(code)
                            .font(VLFont.recoveryCode)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("SP-sync.recoveryCode")
                        Text(L10n.backupRecoveryCodeBody)
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(L10n.backupRecoveryCodeSaved) {
                            state.confirmRecoveryCodeSaved()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("SP-sync.recoveryCode.saved")
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
            // 候选合并入口（切片 D）：navigationDestination(isPresented:) 替代已废弃的
            // hidden NavigationLink(isActive:)（iOS 16 弃用）——同语义，无空标签占位
            .navigationDestination(isPresented: $openMerge) {
                BackupView()
            }
        }
    }
}
