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
    /// 评审修正 U4：§6 四态契约（加载/空/错误/默认）——此前加载失败只进日志，
    /// 视图无从分支：空列表与「还没加载」与「加载失败」三种状态渲染同一形态
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private let store: ObservationStore
    private let allergyStore: AllergyStore
    /// F8.4/§5.10 敏感媒体资产仓（BR-007/008）——保存照片时写入资产并返回 id。
    /// internal：同文件视图（LockedMediaStrip）需读 blur 缩略图（private 跨类型不可见）。
    let mediaAssets: any SensitiveAssetStoring
    private let logger = Logger(subsystem: "com.vitaliber", category: "observations")

    /// 最近一次请求的成员（BR-001 成员隔离：只允许最新请求写回状态）
    private var loadingPatientId: UUID?
    /// 最近一次成功装载的成员——展示类消费者（DoctorShowcaseView）以此
    /// 门控渲染：groups 未装载本成员前绝不渲染（防上一成员敏感媒体泄漏）
    private(set) var loadedPatientId: UUID?

    init(store: ObservationStore, allergyStore: AllergyStore, mediaAssets: any SensitiveAssetStoring) {
        self.store = store
        self.allergyStore = allergyStore
        self.mediaAssets = mediaAssets
    }

    /// FR23.2 过敏三步记录落库（重度触发急救引导由视图判定，Domain SevereReactionRules）
    /// 返回是否保存成功——调用侧据此决定 dismiss 或呈现错误（保存失败
    /// 绝不静默呈现为「已保存」）
    @discardableResult
    func createAllergy(patientId: UUID, substance: String, severity: String,
                       tags: [String], note: String?) async -> Bool {
        do {
            try await allergyStore.create(patientId: patientId, substance: substance,
                                          severity: severity, reactionTags: tags, note: note)
        } catch {
            logger.error("过敏记录失败: \(error)")
            return false
        }
        // 评审修复：只刷新过敏列表，不走全量 load——过敏写入不影响观察组，
        // 全量重载会以保存时捕获的 patientId 重写 loadingPatientId/groups，
        // 成员切换后迟到的保存会击穿 BR-001 守卫（与 deleteAllergy 同型）。
        // 刷新仅在本成员仍是「最近请求成员」时回写。
        guard loadingPatientId == patientId else { return true }
        do {
            let al = try await allergyStore.list(patientId: patientId)
            guard loadingPatientId == patientId else { return true }
            allergies = al
            loadFailed = false
        } catch {
            // 写已成功；只读刷新失败不宣判「保存失败」（误导重试会致重复行），
            // 也不污染全局 loadFailed/loadedPatientId——下次任一 load 自然回补。
            logger.error("过敏列表刷新失败: \(error)")
        }
        return true
    }

    /// FR23.6 删除（删除前明示影响由视图提示）
    func deleteAllergy(id: UUID, patientId: UUID) async {
        do {
            try await allergyStore.delete(id: id)
            // 评审修复：显式传入被删行所属成员，不再经由 loadingPatientId
            // （该值可能指向他处或与展示成员不一致）；且与 createAllergy 同型，
            // 仅在本成员仍是「最近请求成员」时回写刷新（BR-001）
            if loadingPatientId == patientId {
                await load(patientId: patientId)
            }
        } catch {
            logger.error("过敏删除失败: \(error)")
        }
    }

    func load(patientId: UUID) async {
        loadingPatientId = patientId
        isLoading = true
        // 迟到的旧任务退出不得翻转 isLoading——只由最新请求收尾（BR-001）
        defer { if loadingPatientId == patientId { isLoading = false } }
        do {
            // 两个独立仓库并发读（各自 actor），一轮往返
            async let events = store.list(patientId: patientId)
            async let loadedAllergies = allergyStore.list(patientId: patientId)
            let (ev, al) = try await (events, loadedAllergies)
            // 成员切换后晚到的旧结果必须丢弃，不得覆盖当前成员（BR-001）
            guard loadingPatientId == patientId else { return }
            groups = ObservationGroupService.groups(ev, member: patientId)
            allergies = al
            loadedPatientId = patientId
            loadFailed = false
        } catch {
            // 评审修复：失败路径同样必须守卫——旧请求（成员切换后取消的
            // async let 读抛 CancellationError，或过期读失败）不得清除当前
            // 成员的 loadedPatientId / 置 loadFailed（BR-001 双向写回纪律）
            guard loadingPatientId == patientId else { return }
            loadedPatientId = nil
            loadFailed = true
            logger.error("观察加载失败: \(error)")
        }
    }

    // MARK: - FR8.11 观察详情页（SP-14 §5.7.1）

    enum DetailPhase: Equatable { case loading, loaded, failed }
    private(set) var detail: ObservationEvent?
    private(set) var detailPhase: DetailPhase = .loading
    /// 最近一次请求的详情 id——与 load 同型的晚到丢弃守卫（BR-001 双向写回纪律）
    private var loadingDetailId: UUID?

    func loadDetail(id: UUID) async {
        loadingDetailId = id
        detailPhase = .loading
        do {
            let fetched = try await store.fetch(id: id)
            // 评审修复：晚到的旧详情读不得覆盖新详情（详情页 A→B 连开，
            // A 的慢读在 B 就绪后落盘会把 B 页渲染成 A）
            guard loadingDetailId == id else { return }
            detail = fetched
            detailPhase = .loaded
        } catch {
            guard loadingDetailId == id else { return }
            logger.error("观察详情加载失败: \(error)")
            detail = nil
            detailPhase = .failed
        }
    }

    /// FR8.7 事后补字段行内写回（只更新提交列 + updated_at）；成功即按提交值
    /// 就地镜像详情——不再依赖一次可能失败的全量重取（重取失败会把刚保存
    /// 成功的页面翻成失败态，与「已保存」提示自相矛盾；与 createAllergy
    /// 「只刷新受影响面」同族）
    @discardableResult
    func saveExtended(id: UUID, bodyPart: String?, durationMin: Int?, frequency: String?,
                      isFirst: Bool?, trigger: String?, accompanying: String?,
                      painScore: Int?, medsDiet: String?, consultedDoctor: Bool?,
                      description: String?) async -> Bool {
        do {
            try await store.updateExtended(id: id, bodyPart: bodyPart,
                                           durationMin: durationMin, frequency: frequency,
                                           isFirst: isFirst, trigger: trigger,
                                           accompanying: accompanying, painScore: painScore,
                                           medsDiet: medsDiet, consultedDoctor: consultedDoctor,
                                           description: description)
            // 写库语义为 COALESCE（非 nil 即覆盖），镜像同型：非 nil 提交值回填，
            // nil 保持现值
            if var current = detail, current.id == id {
                if let v = bodyPart { current.bodyPart = v }
                if let v = durationMin { current.durationMin = v }
                if let v = frequency { current.frequency = v }
                if let v = isFirst { current.isFirst = v }
                if let v = trigger { current.trigger = v }
                if let v = accompanying { current.accompanying = v }
                if let v = painScore { current.painScore = v }
                if let v = medsDiet { current.medsDiet = v }
                if let v = consultedDoctor { current.consultedDoctor = v }
                if let v = description { current.description = v }
                detail = current
            }
            detailPhase = .loaded
            return true
        } catch {
            logger.error("观察补充信息保存失败: \(error)")
            return false
        }
    }

    /// FR8.8 删除：原图随孤儿对账清除（下次启动 reconcileUnreferenced）
    @discardableResult
    func deleteObservation(id: UUID) async -> Bool {
        do {
            try await store.delete(id: id)
            return true
        } catch {
            logger.error("观察删除失败: \(error)")
            return false
        }
    }

    /// 启动对账：清除未被任何观察引用的孤儿照片（崩溃窗口/历史失败残留）。
    /// 失败不阻断启动（§7 显式降级）：本轮留残，下轮再扫。
    func reconcileAssets() async {
        do {
            let referenced = try await store.allReferencedAssetIds()
            await mediaAssets.reconcileUnreferenced(validAssetIds: referenced)
        } catch {
            logger.error("资产对账失败: \(error)")
        }
    }

    /// 保存观察：照片先落敏感资产仓（原图 + blur），再把资产 id 随观察行入库。
    /// 任一环节失败即回滚已保存资产（补偿路径）——绝不产生「无图观察」或孤儿敏感文件。
    /// 返回是否保存成功——调用侧据此决定 dismiss 或保留表单告警（与
    /// createAllergy 同族：保存失败绝不静默呈现为「已保存」）。
    @discardableResult
    func create(patientId: UUID, kind: String, description: String, selfMark: String?,
                photoData: [Data]) async -> Bool {
        var saved: [UUID] = []
        do {
            // 局部 Sendable 快照：TaskGroup 闭包非隔离，直接引用 self.mediaAssets
            // 会触发 Swift 6 显式捕获/隔离检查（CI 编译错），快照捕获合法且语义不变。
            let media = mediaAssets
            let assetIds = try await withThrowingTaskGroup(of: UUID.self) { group in
                for data in photoData {
                    group.addTask { try await media.savePhoto(data, memberId: patientId) }
                }
                var ids: [UUID] = []
                for try await id in group { ids.append(id); saved.append(id) }
                return ids
            }
            try await store.create(patientId: patientId,
                                   kind: ObservationKind(rawValue: kind) ?? .custom,
                                   description: description, selfMark: selfMark,
                                   mediaAssetIds: assetIds.map(\.uuidString))
            // 评审修复：成员切换后迟到的保存不重写共享状态——创建页含成员
            // 切换入口，保存期间切换成员后此 load 会以旧 patientId 击穿
            // BR-001 守卫；切换回该成员时 .task(id:) 自会重载
            if loadingPatientId == patientId {
                await load(patientId: patientId)
            }
            return true
        } catch {
            // 补偿回滚：已落盘的敏感照片与资产行一并清除，不留孤儿（BR-007/008 簿记）
            for id in saved {
                await mediaAssets.removePhoto(id, memberId: patientId)
            }
            logger.error("观察创建失败: \(error)")
            return false
        }
    }
}

struct ObservationListView: View {
    @Environment(AppState.self) private var app
    @Environment(ObservationStoreState.self) private var state
    @Environment(ReminderStore.self) private var reminders
    @State private var showCreate = false

    var body: some View {
        Group {
            if state.loadedPatientId == currentPatientId {
                // 已装载本成员——四态分支（§6 加载/错误/空/默认）
                if state.isLoading && state.groups.isEmpty && state.allergies.isEmpty {
                    skeletonState
                } else if state.loadFailed && state.groups.isEmpty && state.allergies.isEmpty {
                    errorState
                } else if state.groups.isEmpty && state.allergies.isEmpty {
                    emptyState
                } else {
                    contentList
                }
            } else if state.loadFailed {
                // 评审修复：本成员装载失败——即使残留上一成员的旧 groups/
                // allergies 也绝不渲染（BR-001/BR-007 跨成员敏感媒体泄漏），
                // 此前错误分支要求列表为空，残留数据使该分支永不可达
                errorState
            } else {
                // 本成员尚未装载（首载或切换成员装载中）——骨架屏，而非
                // 上一成员的残留内容
                skeletonState
            }
        }
        .navigationTitle(L10n.observationTitle)
        .task(id: currentPatientId) { await state.load(patientId: currentPatientId) }
        .sheet(isPresented: $showCreate) {
            ObservationCreateSheet { kind, desc, mark, photos in
                await state.create(patientId: currentPatientId, kind: kind,
                                   description: desc, selfMark: mark,
                                   photoData: photos)
            }
        }
    }

    /// §6 加载态 = 骨架屏（列表类禁旋转菊花）
    private var skeletonState: some View {
        List {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray5))
                    .frame(height: 72)
            }
        }
    }

    /// §6 错误态 = 行内错误条 + [重试]
    private var errorState: some View {
        List {
            Section {
                HStack {
                    Label(L10n.observationListError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.observationListRetry) {
                        Task { await state.load(patientId: currentPatientId) }
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    /// §6 空态 = 插画 + 一句话 + 唯一主行动按钮
    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.observationListEmpty, systemImage: "clipboard")
        } description: {
            Text(L10n.observationListEmptyHint)
        } actions: {
            Button(L10n.observationCreateTitle) { showCreate = true }
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("SP-14.observation.empty")
    }

    private var contentList: some View {
        List {
            Section(L10n.observationSectionTitle) {
                ForEach(state.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.observationKindName(group.kind)).font(.subheadline)
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
                    // FR8.10 观察随访提醒：一键设置「N 天后提醒对比/复查」
                    .contextMenu {
                        if let latest = group.latest {
                            Button(L10n.observationFollowUpSet) {
                                Task {
                                    await reminders.scheduleObservationFollowUp(
                                        observationId: latest.id,
                                        observedAt: latest.occurredAt,
                                        patientId: app.currentPatientId)
                                }
                            }
                            .accessibilityIdentifier("FR8.10.followUp.set")
                        }
                    }
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
    /// 评审修正 U3：点击解锁查看原图（§5.7.1）——此前媒体条无任何手势，
    /// 原图在 UI 层不可达（SensitiveMediaOriginalView 零调用方，违背
    /// 永久免费「原图/离线访问」红线）。查看器承载逐次认证 + 30s 空闲重锁。
    @State private var viewer: MediaViewerPayload?
    /// 解码缓存：行回收重建时跳过重复解码（blur Data 已在仓内缓存）
    private static let imageCache = NSCache<NSString, UIImage>()

    struct MediaViewerPayload: Identifiable {
        let assetId: UUID
        let caption: String
        /// 认证通过后由查看器回调拉取原图（BR-007：认证前原图字节不得进内存）
        let originalLoader: () async -> Data?
        var id: UUID { assetId }
    }

    var body: some View {
        MediaThumbRow(images: blurImages, size: 56)
            .frame(height: 64)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let first = assetIds.first, let assetId = UUID(uuidString: first) else { return }
                openOriginal(assetId: assetId)
            }
            .fullScreenCover(item: $viewer) { payload in
                NavigationStack {
                    SensitiveMediaOriginalView(imageData: nil,
                                               caption: payload.caption,
                                               assetId: payload.assetId,
                                               originalLoader: payload.originalLoader)
                }
            }
            .accessibilityLabel(L10n.observationMediaUnlockHint)
            .accessibilityIdentifier("SP-14.observation.mediaStrip")
            .task(id: assetIds) {
                // 并发加载 + 保持 assetIds 顺序；任务被取消（滚动/换组）时丢弃结果。
                // 快照在 MainActor 上下文读取（此层级隐式 self 与仓库既有 .task 模式一致），
                // 非隔离 @Sendable 的 TaskGroup/addTask 闭包只捕获这些 Sendable 局部量——
                // 直接引用 self 属性会触发 Swift 6 显式捕获检查（CI 编译错）。
                let state = state
                let member = memberId
                let ids = assetIds
                let results = await withTaskGroup(of: (Int, UIImage?).self) { group in
                    for (index, id) in ids.enumerated() {
                        group.addTask { (index, await Self.thumb(id: id, memberId: member, state: state)) }
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

    /// 点击解锁流程（§5.7.1）：全屏查看器（逐次设备所有者认证 +
    /// 30s 空闲重锁，BR-007/008 由查看器自身执行）。
    /// 评审修正第二轮：原图字节不在点击时预取——loader 由查看器在**认证通过后**
    /// 回调，认证取消的用户从未让原图进内存（BR-007 读取时序）。
    private func openOriginal(assetId: UUID) {
        let media = state.mediaAssets
        let member = memberId
        viewer = MediaViewerPayload(
            assetId: assetId,
            caption: L10n.observationMediaCount(assetIds.count)) {
                do { return try await media.originalData(for: assetId, memberId: member) }
                catch { return nil }   // 原图缺失：静默不可查看（§7 显式降级）
            }
    }
}

struct ObservationCreateSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// 返回是否保存成功——false 时保留表单并告警，绝不静默呈现为「已保存」
    let onCreate: (String, String, String?, [Data]) async -> Bool

    /// SP-14 步骤1：默认值在 onAppear 从 AppState 记忆项回填（FR8.1 默认高亮）
    @State private var kind = ObservationKind.skin.rawValue
    @State private var description = ""
    @State private var selfMark = "unchanged"
    @State private var confirmSet: OcrConfirmationSet?
    @State private var routeMonitor = AudioRouteMonitor()
    @State private var saveFailed = false
    @State private var saving = false

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
    @State private var showMemberPicker = false

    private var photoData: [Data] { cameraData + pickerData }
    private var previews: [UIImage] { cameraThumbs + pickerThumbs }

    /// FR3.3 归属强制确认：保存前整屏醒目二次确认（头像+姓名大字）
    private var currentMember: PatientProfile? {
        app.members.first(where: { $0.id == app.currentPatientId })
    }

    var body: some View {
        NavigationStack {
            Form {
                // FR3.3 归属确认条置顶（SP-14 步骤3：MemberConfirmBar 置顶）
                memberSection
                kindSection
                mediaSection
                detailSection
            }
            .navigationTitle(L10n.observationCreateTitle)
            // FR20.3 L2 场景首用须知（观察拍摄页，一次性确认）
            .sceneDisclosure(scene: "observation")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // FR8.7 三步完成承诺：其余字段全部可选、可事后补——
                    // 保存不得要求描述非空（类型+媒体+归属即完整保存路径）
                    Button(L10n.commonSave) {
                        // 评审修复：保存失败保留表单并告警（SaveFailedAlert 统一
                        // 出口）——此前无条件 dismiss，失败呈现为「已保存」而
                        // 照片已补偿删除、记录丢失（与 AllergyViews 同族）
                        saving = true
                        Task {
                            if await onCreate(kind, description, selfMark, photoData) {
                                dismiss()
                            } else {
                                saveFailed = true
                            }
                            saving = false
                        }
                    }
                    .disabled(loadingPicker || saving)
                    .accessibilityIdentifier("SP-14.observation.save")
                }
            }
            // 保存失败错误态（四态纪律：失败绝不静默呈现为已保存）
            .saveFailedAlert(title: L10n.observationSaveFailed,
                             hint: L10n.observationSaveFailedHint,
                             isPresented: $saveFailed)
            .sheet(isPresented: $showMemberPicker) {
                MemberPickerSheet()
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
                // MainActor Task（评审修正）：不用 Task.detached——@Sendable 闭包捕获
                // 视图 @State 在 Swift 6 严格并发下有隔离风险；加载与下采样在
                // MediaImport.loadWithThumbnails 的非隔离上下文中执行，只回传 Sendable Data。
                Task {
                    let (loaded, thumbsData) = await MediaImport.loadWithThumbnails(items)
                    guard gen == loadGeneration else { return }   // 旧代结果作废（评审修正：曾发生竞态覆盖）
                    // 跨源上限钳制（评审修正）：相册选择本身不受相机已拍数约束，
                    // 超限截断，总量恒 ≤ maxPhotos。cameraCount 必须取完成时点
                    // 的实值——此前在选择时点捕获，加载期间相机可再拍满 6 张，
                    // 完成时 allowed 仍按 0 算，总量可达 12 张
                    let allowed = max(0, maxPhotos - cameraData.count)
                    pickerData = Array(loaded.prefix(allowed))
                    pickerThumbs = thumbsData.prefix(allowed).compactMap(UIImage.init(data:))
                    loadingPicker = false
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
    /// FR3.3 归属确认条（保存前醒目二次确认；切换经成员抽屉，不静默保存）
    private var memberSection: some View {
        Section {
            MemberConfirmBar(
                patientName: currentMember?.displayName ?? app.owner?.displayName ?? L10n.help_appName,
                relation: currentMember?.relation ?? L10n.member_relationSelf) {
                    showMemberPicker = true
                }
        }
    }

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
            // FR8.3 专项文案（V3.72）：大小便等敏感类型拍摄页固定提示——
            // 照片颜色受光线/白平衡/容器影响，不能用于自我诊断（BR-006 防线）
            if let k = ObservationKind(rawValue: kind), k == .stool || k == .urine {
                Text(L10n.observationColorDisclaimer)
                    .font(.caption)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
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
        // 评审修复：占用数须含仍在加载中的相册选择（pickerItems 为选择态、
        // pickerData 为已落值），否则相册加载窗口内相机可把总量拍超 maxPhotos
        let occupied = cameraData.count + max(pickerData.count, pickerItems.count)
        guard occupied < maxPhotos,
              let data = image.jpegData(compressionQuality: 0.8) else { return }
        cameraData.append(data)
        cameraThumbs.append(MediaImport.downsample(data) ?? image)
    }
}
