import SwiftUI
import UIKit
import PhotosUI
import os
import Domain
import Infrastructure
import Protocols

/// F8 观察模块（M1c 切片）：观察创建 + 列表 + 敏感保护链（BR-007/008）。
/// 类型名称走 L10n.observationKindName，图标走 DesignSystem 的 ObservationKind.icon 扩展。

/// 缩略图横排（列表 blur 条与创建页预览共用）：一处定义圆角/填充/间距，
/// 避免多处复制漂移。
private struct MediaThumbRow: View {
    let images: [UIImage]
    let size: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            ForEach(images.indices, id: \.self) { i in
                Image(uiImage: images[i])
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

@MainActor
@Observable
final class ObservationStoreState {
    private(set) var groups: [ObservationGroup] = []
    private(set) var allergies: [AllergyStore.AllergyRow] = []
    private let store: ObservationStore
    private let allergyStore: AllergyStore
    /// F8.4/§5.10 敏感媒体资产仓（BR-007/008）——保存照片时写入资产并返回 id。
    /// internal：同文件视图（LockedMediaStrip）需读 blur 缩略图（private 跨类型不可见）。
    let mediaAssets: any SensitiveAssetStoring
    private let logger = Logger(subsystem: "com.vitaliber", category: "observations")

    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?

    init(store: ObservationStore, allergyStore: AllergyStore, mediaAssets: any SensitiveAssetStoring) {
        self.store = store
        self.allergyStore = allergyStore
        self.mediaAssets = mediaAssets
    }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        do {
            // 两个独立仓库并发读（各自 actor），一轮往返
            async let events = store.list(patientId: patientId)
            async let loadedAllergies = allergyStore.list(patientId: patientId)
            let (ev, al) = try await (events, loadedAllergies)
            // 成员切换后晚到的旧结果必须丢弃，不得覆盖当前成员（BR-001）
            guard loadingPatientId == patientId else { return }
            groups = ObservationGroupService.groups(ev, member: patientId)
            allergies = al
        } catch {
            logger.error("观察加载失败: \(error)")
        }
    }

    /// 保存观察：照片先落敏感资产仓（原图 + blur），再把资产 id 随观察行入库。
    /// 任一环节失败即回滚已保存资产（补偿路径）——绝不产生「无图观察」或孤儿敏感文件。
    func create(patientId: UUID, kind: String, description: String, selfMark: String?,
                photoData: [Data]) async {
        var saved: [UUID] = []
        do {
            let assetIds = try await withThrowingTaskGroup(of: UUID.self) { group in
                for data in photoData {
                    group.addTask { try await mediaAssets.savePhoto(data, memberId: patientId) }
                }
                var ids: [UUID] = []
                for try await id in group { ids.append(id); saved.append(id) }
                return ids
            }
            try await store.create(patientId: patientId, kind: kind,
                                   description: description, selfMark: selfMark,
                                   mediaAssetIds: assetIds.map(\.uuidString))
            await load(patientId: patientId)
        } catch {
            // 补偿回滚：已落盘的敏感照片与资产行一并清除，不留孤儿（BR-007/008 簿记）
            for id in saved {
                await mediaAssets.removePhoto(id, memberId: patientId)
            }
            logger.error("观察创建失败: \(error)")
        }
    }
}

struct ObservationListView: View {
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state
    @State private var showCreate = false

    var body: some View {
        List {
            Section(L10n.observationSectionTitle) {
                ForEach(state.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.observationKindName(forKey: group.kind)).font(.subheadline)
                            Spacer()
                            if let count = group.latest?.mediaAssetIds.count, count > 0 {
                                // BR-007/008：列表只显示「含图已锁定」徽标，绝不直接渲染原图
                                Label {
                                    Text(L10n.observationMediaBadge(count))
                                } icon: {
                                    VLIcon.lock.resizable().frame(width: 14, height: 14)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("SP-14.observation.mediaBadge")
                            }
                        }
                        Text(L10n.observationGroupSummary(group.occurrences.count, group.selfMark ?? "-"))
                            .font(.caption2).foregroundStyle(.secondary)
                        if let ids = group.latest?.mediaAssetIds, !ids.isEmpty,
                           let memberId = group.latest?.memberId {
                            LockedMediaStrip(assetIds: ids, memberId: memberId)
                        }
                    }
                    .accessibilityIdentifier("SP-14.observation.group")
                }
                Button {
                    showCreate = true
                } label: {
                    Label(L10n.observationCreateTitle, systemImage: "plus")
                }
                .accessibilityIdentifier("SP-14.observation.add")
            }
            Section(L10n.observationAllergySection) {
                ForEach(state.allergies, id: \.id) { a in
                    HStack {
                        Text(a.substance).font(.body)
                        Spacer()
                        Text(a.severity).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Color("semantic-warning", bundle: .main).opacity(0.15)))
                    }
                    .accessibilityIdentifier("SP-50.allergy.row")
                }
            }
        }
        .navigationTitle(L10n.observationTitle)
        .task(id: currentPatientId) { await state.load(patientId: currentPatientId) }
        .sheet(isPresented: $showCreate) {
            ObservationCreateSheet { kind, desc, mark, photos in
                Task { await state.create(patientId: currentPatientId, kind: kind,
                                          description: desc, selfMark: mark,
                                          photoData: photos) }
                showCreate = false
            }
        }
    }

    private var currentPatientId: UUID { app.currentPatientId }
}

/// 列表行内的敏感媒体条（BR-007/008）：只渲染 blur 缩略图（§5.10 锁定 UI 永远只读 blur 版），
/// 原图 URL/数据绝不进入本视图。blur 本身不可辨识，故此处不再套解锁容器——
/// 解锁查看原图属全屏查看器职责（tech §11 清偿表）。
struct LockedMediaStrip: View {
    let assetIds: [String]
    let memberId: UUID
    @Environment(ObservationStoreState.self) private var state
    @State private var blurImages: [UIImage] = []
    /// 解码缓存：行回收重建时跳过重复解码（blur Data 已在仓内缓存）
    private static let imageCache = NSCache<NSString, UIImage>()

    var body: some View {
        MediaThumbRow(images: blurImages, size: 56)
            .frame(height: 64)
            .accessibilityIdentifier("SP-14.observation.mediaStrip")
            .task(id: assetIds) {
                // 并发加载 + 保持 assetIds 顺序；任务被取消（滚动/换组）时丢弃结果
                var loaded: [UIImage] = []
                let results = await withTaskGroup(of: (Int, UIImage?).self) { group in
                    for (index, id) in assetIds.enumerated() {
                        group.addTask { (index, await Self.thumb(id: id, memberId: memberId, state: state)) }
                    }
                    var out: [(Int, UIImage)] = []
                    for await (index, img) in group {
                        if let img { out.append((index, img)) }
                    }
                    return out.sorted { $0.0 < $1.0 }.map(\.1)
                }
                guard !Task.isCancelled else { return }
                blurImages = results
            }
    }

    @MainActor
    private static func thumb(id: String, memberId: UUID, state: ObservationStoreState) async -> UIImage? {
        guard let uuid = UUID(uuidString: id) else { return nil }   // 损坏 id 跳过该张，不做无谓查询
        if let cached = imageCache.object(forKey: id as NSString) { return cached }
        guard let data = try? await state.mediaAssets.blurData(for: uuid, memberId: memberId), // try?-ok: 单张 blur 读取失败跳过该张，不阻断列表（§7 显式降级）
              let img = UIImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: id as NSString)
        return img
    }
}

struct ObservationCreateSheet: View {
    @Environment(AppState.self) private var app
    let onCreate: (String, String, String?, [Data]) -> Void

    /// SP-14 步骤1：默认值在 onAppear 从 AppState 记忆项回填（FR8.1 默认高亮）
    @State private var kind = ObservationKind.skin.rawValue
    @State private var description = ""
    @State private var selfMark = "unchanged"
    @State private var confirmSet: OcrConfirmationSet?
    @State private var routeMonitor = AudioRouteMonitor()

    /// SP-14 步骤2 媒体：相册与相机分源存储——相册 onChange 全量替换，
    /// 相机逐张追加；两者互不覆盖（评审修正：曾整体替换致相机照片被静默丢弃）。
    private let maxPhotos = 6
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pickerData: [Data] = []
    @State private var cameraData: [Data] = []
    /// 下采样预览（ImageIO，§5.10 原图不整图解码进内存），分源存储保证
    /// 预览顺序与 photoData（cameraData + pickerData）一致（评审修正）。
    @State private var cameraThumbs: [UIImage] = []
    @State private var pickerThumbs: [UIImage] = []
    @State private var loadingPicker = false
    @State private var loadGeneration = 0
    @State private var showCamera = false

    private var photoData: [Data] { cameraData + pickerData }
    private var previews: [UIImage] { cameraThumbs + pickerThumbs }

    var body: some View {
        NavigationStack {
            Form {
                kindSection
                mediaSection
                detailSection
            }
            .navigationTitle(L10n.observationCreateTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave) {
                        onCreate(kind, description, selfMark, photoData)
                    }
                    .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty || loadingPicker)
                    .accessibilityIdentifier("SP-14.observation.save")
                }
            }
            .sheet(item: $confirmSet) { set in
                VoiceConfirmSheet(
                    set: set,
                    decision: ReadbackPolicy.decide(route: routeMonitor.route,
                                                    preference: app.readbackPreference,
                                                    careMode: app.careMode),
                    onSpeak: { app.speak($0) },
                    onConfirm: { confirmed in
                        description = confirmed.confirmedFields.first?.value ?? description
                        confirmSet = nil
                    },
                    onRetry: { confirmSet = nil },
                    onCancel: { confirmSet = nil })
                .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    appendCamera(image)
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .onChange(of: pickerItems) { _, items in
                loadGeneration += 1
                let gen = loadGeneration
                loadingPicker = true
                Task.detached(priority: .userInitiated) {
                    var loaded = await MediaImport.load(items)
                    let thumbs = loaded.compactMap { MediaImport.downsample($0) }
                    await MainActor.run {
                        guard gen == loadGeneration else { return }   // 旧代结果作废（评审修正：曾发生竞态覆盖）
                        // 跨源上限钳制（评审修正）：相册选择本身不受相机已拍数约束，
                        // 超限截断，总量恒 ≤ maxPhotos
                        let allowed = max(0, maxPhotos - cameraData.count)
                        if loaded.count > allowed {
                            loaded = Array(loaded.prefix(allowed))
                        }
                        pickerData = loaded
                        pickerThumbs = Array(thumbs.prefix(allowed))
                        loadingPicker = false
                    }
                }
            }
            .onAppear {
                kind = app.observationLastKind
                routeMonitor.start()
            }
            .onDisappear { routeMonitor.stop() }
        }
    }

    // MARK: - 分区（body 保持三层可读，评审修正）

    /// SP-14 步骤1：2×4 大图标宫格（FR8.1 八类），默认记忆上次选择
    private var kindSection: some View {
        Section(L10n.observationKindSection) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ObservationKind.allCases, id: \.rawValue) { item in
                    kindCell(item)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// SP-14 步骤2：拍摄/选择媒体——照片属敏感媒体（BR-007/008）：
    /// 锁定占位只含锁图标与计数（无可辨识内容），解锁后才是缩略图。
    private var mediaSection: some View {
        Section(L10n.observationMediaSection) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: maxPhotos, matching: .images) {
                Label(L10n.observationMediaAddAlbum, systemImage: "photo.on.rectangle")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("SP-14.observation.album")
            Button {
                // 无相机设备（模拟器/无摄像头机型）直接呈现会抛 NSInvalidArgumentException
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
                showCamera = true
            } label: {
                Label(L10n.observationMediaAddCamera, systemImage: "camera")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("SP-14.observation.camera")
            if !previews.isEmpty {
                SensitiveMediaContainer { _ in
                    // 锁定态占位：绝不含可识别内容（BR-007）
                    HStack(spacing: 12) {
                        VLIcon.lock.resizable().frame(width: 32, height: 32)
                        Text(L10n.observationMediaCount(photoData.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                } content: { _ in
                    MediaThumbRow(images: previews, size: 72)
                }
                .frame(height: 96)
                .contentShape(Rectangle())   // 空白区也参与点击命中（解锁手势不落空）
                .accessibilityIdentifier("SP-14.observation.mediaPreview")
            }
        }
    }

    private var detailSection: some View {
        Section {
            TextField(L10n.observationDescription, text: $description, axis: .vertical)
                .lineLimit(2...5)
            // FR8.9 观察语音速记（纯转写层）：端上听写 → FR17.13 统一模板确认 →
            // 确认后才落描述字段（评审修正：确认前不预填，取消/重试不留未确认文本）
            VoiceDictationButton { text, confidence in
                // FR17.13-entry: 观察速记 —— 走统一模板，不自建确认逻辑
                confirmSet = VoiceInputTemplate.confirmationSet(drafts: [
                    FieldDraft(key: "description", value: text, confidence: confidence)
                ])
            }
            .accessibilityIdentifier("SP-14.observation.dictation")
            Picker(L10n.observationSelfMark, selection: $selfMark) {
                Text(L10n.observationTrendImproved).tag("improved")
                Text(L10n.observationTrendUnchanged).tag("unchanged")
                Text(L10n.observationTrendWorsened).tag("worsened")
            }
        }
    }

    /// 2×4 宫格单元：图标 + 类型名，选中态品牌描边 + 对勾（记忆上次选择为默认高亮）
    @ViewBuilder
    private func kindCell(_ item: ObservationKind) -> some View {
        let selected = kind == item.rawValue
        Button {
            kind = item.rawValue
            app.observationLastKind = item.rawValue
        } label: {
            VStack(spacing: 8) {
                item.icon.resizable().frame(width: 40, height: 40)
                Text(L10n.observationKindName(item)).font(.footnote)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color("brand-primary", bundle: .main))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(Color("bg-grouped", bundle: .main)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color("brand-primary", bundle: .main) : .clear,
                              lineWidth: selected ? 1.5 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.observationKindName(item))
        .accessibilityIdentifier("SP-14.observation.kind.\(item.rawValue)")
    }

    private func appendCamera(_ image: UIImage) {
        guard cameraData.count + pickerData.count < maxPhotos,
              let data = image.jpegData(compressionQuality: 0.8) else { return }
        cameraData.append(data)
        cameraThumbs.append(MediaImport.downsample(data) ?? image)
    }
}
