import SwiftUI
import UIKit
import os
import Domain
import Infrastructure

/// FR9.13a 药品求助卡 UI：多选批次 → 位置照片显式勾选（默认不含）→
/// 系统分享渠道发送。每次分享由调用方写审计（§16.5）。
/// 发送后状态页（FR24.2）随发送侧 F24 接线——本卡生成与分享即 M2 范围。
struct MedicationHelpCardSheet: View {
    let items: [MedicationStore.InventorySummaryItem]
    var storageNotes: [UUID: String] = [:]          // lotId → 存放位置文字
    var onShare: (([MedicationHelpCardRules.Input]) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<UUID> = []
    @State private var includePhotos: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section("选择药品批次（可多选）") {
                    ForEach(items) { item in
                        Button {
                            if selectedIds.contains(item.lotId) {
                                selectedIds.remove(item.lotId)
                                includePhotos.remove(item.lotId)
                            } else {
                                selectedIds.insert(item.lotId)
                            }
                        } label: {
                            HStack {
                                VLIcon.checkCircle.resizable().frame(width: 20, height: 20)
                                    .opacity(selectedIds.contains(item.lotId) ? 1 : 0.2)
                                VStack(alignment: .leading) {
                                    Text(item.medicationName)
                                    Text("约剩 \(item.remainingPlanUnits, specifier: "%g") \(item.unitKind)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("FR9.13a.card.select")
                    }
                }
                if !selectedIds.isEmpty {
                    Section("位置照片（默认不包含）") {
                        Toggle(isOn: Binding(
                            get: { !includePhotos.isEmpty },
                            set: { newValue in
                                includePhotos = newValue ? selectedIds : []
                            })) {
                            Text("包含存放位置照片（外发家庭内部影像，请确认确有需要）")
                        }
                        .accessibilityIdentifier("FR9.13a.card.photoOptIn")
                    }
                    Text("卡片内容：药名/规格/剩余量/存放位置文字/效期。不包含任何诊断类信息。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("药品求助卡")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成并分享") {
                        var inputs: [MedicationHelpCardRules.Input] = []
                        for item in items where selectedIds.contains(item.lotId) {
                            inputs.append(MedicationHelpCardRules.Input(
                                lotId: item.lotId, medicationName: item.medicationName,
                                spec: item.spec, remainingUnits: item.remainingPlanUnits,
                                unitKind: item.unitKind, expireAt: item.expireAt,
                                storageNote: storageNotes[item.lotId],
                                includeStoragePhoto: includePhotos.contains(item.lotId)))
                        }
                        onShare?(inputs)
                        dismiss()
                    }
                    .disabled(selectedIds.isEmpty)
                    .accessibilityIdentifier("FR9.13a.card.share")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 系统分享宿主（UIActivityViewController 包装——ShareLink 无法承载
/// 「照片显式勾选」的附件组合与审计回调）。
struct HelpCardShareHost: UIViewControllerRepresentable {
    let text: String
    let photoAttachments: [Data]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [text]
        for data in photoAttachments {
            if let image = UIImage(data: data) { items.append(image) }
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
