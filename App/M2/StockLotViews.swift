import SwiftUI
import Domain
import Infrastructure

/// SP-17 批次详情/编辑（ui-ux §5.22.1 · FR9.10/9.11）：档案唯一完整呈现面。
/// 双轨库存卡（FR9.8 安全线/确认线）、效期状态、事后补填（消除待办）、
/// 盘点校正（FR9.16）、废弃软删；过期批次零用药建议（BR-006）。
struct StockLotDetailView: View {
    let lotId: UUID

    @Environment(M2HubStore.self) private var hub
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable { case loading, loaded, failed }
    @State private var phase: Phase = .loading
    @State private var lot: MedicationStore.LotRow?
    @State private var showEdit = false
    @State private var showReconcile = false
    @State private var showDiscard = false
    @State private var discardDoneToast = false

    var body: some View {
        Group {
            switch phase {
            case .loading: ProgressView()
            case .failed:
                ContentUnavailableView(L10n.lotDetailLoadFailed, systemImage: "exclamationmark.triangle")
            case .loaded:
                if let lot { content(lot) }
                else { ContentUnavailableView(L10n.lotDetailLoadFailed, systemImage: "pills") }
            }
        }
        .navigationTitle(lot?.medicationName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: lotId) { await load() }
        .sheet(isPresented: $showEdit) {
            if let lot {
                StockLotEditView(lot: lot) { draft in
                    await save(draft)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showReconcile) {
            if let lot {
                InventoryReconcileSheet(item: MedicationStore.InventorySummaryItem(
                    lotId: lot.lotId, medicationName: lot.medicationName, spec: lot.spec,
                    unitKind: lot.unitKind, remainingPlanUnits: lot.remainingPlanUnits,
                    remainingConfirmedUnits: lot.remainingConfirmedUnits,
                    expireAt: lot.expireAt, storageNote: lot.storageNote,
                    approxDaysLeft: nil, refillTier: nil)) { count in
                    Task {
                        await hub.reconcileLot(item: MedicationStore.InventorySummaryItem(
                            lotId: lot.lotId, medicationName: lot.medicationName, spec: lot.spec,
                            unitKind: lot.unitKind, remainingPlanUnits: lot.remainingPlanUnits,
                            remainingConfirmedUnits: lot.remainingConfirmedUnits,
                            expireAt: lot.expireAt, storageNote: lot.storageNote,
                            approxDaysLeft: nil, refillTier: nil), physicalCount: count)
                        showReconcile = false
                        await load()
                    }
                }
                .presentationDetents([.medium])
            }
        }
        .alert(L10n.lotDiscardTitle, isPresented: $showDiscard) {
            Button(L10n.lotDiscard, role: .destructive) {
                Task {
                    do {
                        try await hub.updateLot(id: lotId, totalUnits: lot?.totalUnits ?? 0,
                                                unitKind: lot?.unitKind ?? "tablet",
                                                openedAt: lot?.openedAt, expireAt: lot?.expireAt,
                                                storageNote: lot?.storageNote, status: "discarded")
                        discardDoneToast = true
                    } catch {
                        phase = .failed
                    }
                }
            }
            Button(L10n.commonCancel, role: .cancel) { }
        }
        .alert(L10n.lotDiscardDone, isPresented: $discardDoneToast) {
            Button(L10n.onboard_gotIt, role: .cancel) { dismiss() }
        }
    }

    private func load() async {
        phase = .loading
        do {
            lot = try await hub.fetchLot(id: lotId)
            phase = .loaded
        } catch {
            phase = .failed
        }
    }

    private func save(_ draft: LotEditDraft) async {
        do {
            try await hub.updateLot(id: lotId, totalUnits: draft.totalUnits,
                                    unitKind: draft.unitKind, openedAt: draft.openedAt,
                                    expireAt: draft.expireAt, storageNote: draft.storageNote,
                                    status: lot?.status ?? "active")
            showEdit = false
            await load()
        } catch {
            // 保存失败保留表单（sheet 不关闭，错误条由编辑页呈现）
            return
        }
    }

    private func content(_ lot: MedicationStore.LotRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(lot)
                dualTrackCard(lot)
                archiveCard(lot)
                actions(lot)
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ lot: MedicationStore.LotRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(lot.medicationName).font(.title3.bold())
                if let spec = lot.spec { Text(spec).font(.subheadline).foregroundStyle(.secondary) }
                GradeBadge(grade: "C")
                Spacer()
                statusBadge(lot.status)
            }
            // FR9.11：过期的是批次——显著标注，但不渲染任何用药建议（BR-006）
            if lot.status == "expired" || (lot.expireAt.map { $0 < Date() } ?? false) {
                Label(L10n.lotExpiredBadge, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(Color("grade-d", bundle: .main))
                    .accessibilityIdentifier("SP-17.expired.badge")
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        Text(Self.statusName(status))
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(status == "expired" ? Color("grade-d", bundle: .main) : Color(.systemGray5)))
            .foregroundStyle(status == "expired" ? .white : .primary)
    }

    private func dualTrackCard(_ lot: MedicationStore.LotRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.inventory_dualLine).font(.headline)
            Text(L10n.inventoryDualLine(MedicalNumberFormat.quantity(lot.remainingPlanUnits), lot.unitKind, MedicalNumberFormat.quantity(lot.remainingConfirmedUnits)))
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
    }

    private func archiveCard(_ lot: MedicationStore.LotRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.lotArchiveTitle).font(.headline)
            archiveRow(L10n.lotTotalUnits, MedicalNumberFormat.quantity(lot.totalUnits) + " " + lot.unitKind)
            archiveRow(L10n.lotOpenedAt, lot.openedAt?.formatted(date: .abbreviated, time: .omitted))
            // FR9.10：效期缺失 = 待补填（进批次补录待办）
            if let expireAt = lot.expireAt {
                archiveRow(L10n.lotExpireAt, expireAt.formatted(date: .abbreviated, time: .omitted))
            } else {
                Label(L10n.lotExpireUnknown, systemImage: "clock.badge.questionmark")
                    .font(.caption).foregroundStyle(Color("grade-d", bundle: .main))
                    .accessibilityIdentifier("SP-17.expire.missing")
            }
            archiveRow(L10n.lotStorage, lot.storageNote)
            archiveRow(L10n.lotLastReconciled, lot.lastReconciledAt.formatted(date: .abbreviated, time: .shortened))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
    }

    @ViewBuilder
    private func archiveRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Text(value)
            }
            .font(.footnote)
        }
    }

    private func actions(_ lot: MedicationStore.LotRow) -> some View {
        VStack(spacing: 12) {
            Button {
                showEdit = true
            } label: {
                Label(L10n.lotEdit, systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("SP-17.edit")
            Button {
                showReconcile = true
            } label: {
                Label(L10n.inventory_fixCount, systemImage: "checklist").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("SP-17.reconcile")
            Button(role: .destructive) {
                showDiscard = true
            } label: {
                Label(L10n.lotDiscard, systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("SP-17.discard")
        }
    }

    static func statusName(_ status: String) -> String {
        switch status {
        case "depleted": return L10n.lotStatusDepleted
        case "expired": return L10n.lotStatusExpired
        case "discarded": return L10n.lotStatusDiscarded
        default: return L10n.lotStatusActive
        }
    }
}

/// SP-17 编辑草稿（sheet 内编辑，保存时全字段提交；效期/位置可清空=未知）
struct LotEditDraft {
    var totalUnits: Double
    var unitKind: String
    var openedAt: Date?
    var expireAt: Date?
    var storageNote: String?
}

struct StockLotEditView: View {
    let lot: MedicationStore.LotRow
    let onSave: (LotEditDraft) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var totalText = ""
    @State private var unitKind = "tablet"
    @State private var openedAt: Date?
    @State private var expireAt: Date?
    @State private var storageNote = ""
    @State private var hasOpenedDate = false
    @State private var hasExpireDate = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lotArchiveTitle) {
                    TextField(L10n.lotTotalUnits, text: $totalText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("SP-17.edit.total")
                    Picker(L10n.lotUnitKind, selection: $unitKind) {
                        ForEach(["tablet", "capsule", "patch", "vial"], id: \.self) { kind in
                            Text(L10n.lotUnitName(kind)).tag(kind)
                        }
                    }
                }
                Section(L10n.lotOpenedAt) {
                    Toggle(L10n.lotOpenedAt, isOn: $hasOpenedDate)
                    if hasOpenedDate {
                        DatePicker(L10n.lotOpenedAt, selection: Binding(get: { openedAt ?? Date() }, set: { openedAt = $0 }), displayedComponents: .date)
                    }
                }
                Section(L10n.lotExpireAt) {
                    // 效期可清空=未知（FR9.10 稍后补填 → 待办）
                    Toggle(L10n.lotExpireAt, isOn: $hasExpireDate)
                    if hasExpireDate {
                        DatePicker(L10n.lotExpireAt, selection: Binding(get: { expireAt ?? Date() }, set: { expireAt = $0 }), displayedComponents: .date)
                    }
                }
                Section(L10n.lotStorage) {
                    TextField(L10n.lotStorage, text: $storageNote)
                    // 常用位置标签 chips（FR9.10）
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach([L10n.lotStorageFridge, L10n.lotStorageNightstand,
                                     L10n.lotStorageCabinet, L10n.lotStorageOther], id: \.self) { label in
                                Button(label) { storageNote = label }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                if saveFailed {
                    Label(L10n.lotEditFailed, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .navigationTitle(L10n.lotEditTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave) { save() }
                        .disabled(totalText.isEmpty)
                        .accessibilityIdentifier("SP-17.edit.save")
                }
            }
            .onAppear { prefill() }
        }
    }

    private func prefill() {
        totalText = MedicalNumberFormat.quantity(lot.totalUnits)
        unitKind = lot.unitKind
        openedAt = lot.openedAt
        expireAt = lot.expireAt
        storageNote = lot.storageNote ?? ""
        hasOpenedDate = lot.openedAt != nil
        hasExpireDate = lot.expireAt != nil
    }

    private func save() {
        guard let total = Double(totalText.replacingOccurrences(of: ",", with: ".")), total > 0 else {
            saveFailed = true
            return
        }
        let draft = LotEditDraft(totalUnits: total, unitKind: unitKind,
                                 openedAt: hasOpenedDate ? openedAt : nil,
                                 expireAt: hasExpireDate ? expireAt : nil,
                                 storageNote: storageNote.isEmpty ? nil : storageNote)
        Task {
            await onSave(draft)
        }
    }
}
