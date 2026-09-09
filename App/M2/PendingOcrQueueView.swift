import SwiftUI
import Domain
import Infrastructure

/// FR6.8 待确认聚合队列（SP-53 · ui-ux §5.30，V3.39 对齐）：
/// 活管线（SP-11 确认卡）确认即入库（grade 'C'）；机器识别未确认文本以
/// grade 'D' 文档形态入库（如 PDF 导入、无确认环节的导入路径）——队列跨文档
/// 聚合全部 D 级文档，逐条可「确认」（D→C，BR-003 事实链闸门：确认后才进入
/// 检索与 AI 事实链）或跳回来源文档原文（BR-002）。
/// FR2.3：超过 72 小时未处理的文档置顶钉住（重复置顶提醒）。
/// V3.39 前本视图消费 app.timeline 投影镜像（旧向导管线专属），该镜像已随
/// 向导简化删除——DocumentStore 是唯一生产事实源。
struct PendingOcrQueueView: View {
    @Environment(AppState.self) private var app
    @Environment(DocumentsState.self) private var docs
    @Environment(AppRouter.self) private var router
    /// §5.30 筛选（V3.72）：成员 + 时间窗（全部/3 天/72h+）
    @State private var memberFilter: UUID?
    @State private var windowFilter: Int = 0   // 0=全部 1=3 天 2=72h+
    @State private var loading = true

    /// 72h 置顶钉住（FR2.3/FR6.8 排序规则）+ 新到旧。
    /// 数据源 = DocumentsState.pendingDocuments（跨成员聚合）——第四轮全仓
    /// 审查修复：此前读 docs.documents（仅当前成员），成员筛选对其他成员恒空。
    /// 第八轮全仓审查修复（排序比较器重复日历运算）：isOverdue 含
    /// DayArithmetic 日历运算，原比较器每次比较对 a/b 各算一遍 =
    /// O(n log n) 次日历日计算，且行内渲染再算一遍。先映射一次性
    /// 预计算逾期旗标，排序/渲染共用同一结果（携旗标贯穿，行内不重算）。
    private var pendingRows: [(doc: DocumentStore.DocumentRow, overdue: Bool)] {
        docs.pendingDocuments.filter { doc in
            (memberFilter == nil || doc.patientId == memberFilter)
                && windowMatch(doc)
        }
        .map { (doc: $0, overdue: PendingOcrRules.isOverdue(createdAt: $0.createdAt)) }
        .sorted { a, b in
            if a.overdue != b.overdue { return a.overdue }
            return a.doc.createdAt > b.doc.createdAt
        }
    }

    var body: some View {
        // 单次求值：此前 pendingRows 在 isEmpty/count/ForEach 各算一遍
        // （每遍重做 filter + isOverdue 日历运算 + 排序）
        let rows = pendingRows
        Group {
            if loading && rows.isEmpty {
                ProgressView()
            } else if rows.isEmpty && docs.pendingLoadError != nil {
                ContentUnavailableView {
                    Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                } actions: { Button(L10n.retry) { Task { await load() } } }
            } else if rows.isEmpty {
                ContentUnavailableView(L10n.ocrQueueEmpty, systemImage: "checkmark.seal",
                                       description: Text(docs.pendingDocuments.isEmpty ? L10n.ocrQueueEmptyHint : L10n.homeEmptyFilter))
                    .accessibilityIdentifier("SP-53.queue.empty")
            } else {
                List {
                    Section {
                        if docs.pendingLoadError != nil {
                            Label(L10n.docImportFailed, systemImage: "exclamationmark.triangle")
                            Button(L10n.retry) { Task { await load() } }
                        }
                        Text(L10n.ocrQueueCount(rows.count))
                            .font(.subheadline)
                        // BR-003 诚实性说明：D 级文档未确认前不进检索与 AI 事实链
                        Text(L10n.ocrQueueHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // id 用文档自身 id（此前 \.offset 位置身份：确认一条后
                    // 行序整体移位，SwiftUI 按位置复用行视图，标题/徽章与
                    // accessibilityIdentifier 短暂错配）
                    ForEach(rows, id: \.doc.id) { row in
                        let doc = row.doc
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(doc.title ?? L10n.docUntitled)
                                    .font(.subheadline)
                                // GradeBadge 全仓唯一渲染出口（第四轮全仓审查修复：
                                // 原手写 Capsule 徽章缺虚线边框与「待确认」角标，
                                // 关怀模式/高对比主题下不随语义令牌重映射）
                                GradeBadge(grade: "D")
                                if row.overdue {
                                    Text(L10n.ocrQueue72h)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color("semantic-danger", bundle: .main).opacity(0.12)))
                                        .foregroundStyle(Color("semantic-danger", bundle: .main))
                                }
                                Spacer()
                                // FR6.8 一键跳回来源文档原文（BR-002）
                                Button(L10n.ocrQueueJumpSource) {
                                    router.navigate(to: .documentDetail(doc.id))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .frame(minHeight: 44)   // 触点≥44pt（审查修复）
                            }
                            Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            OCRReviewOwnerRow(patientId: doc.patientId)
                            NavigationLink(L10n.docConfirmText) {
                                DocumentReviewRouteView(documentId: doc.id, patientId: doc.patientId)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .frame(minHeight: 44)   // 触点≥44pt（审查修复）
                            .accessibilityIdentifier("SP-53.queue.confirm.doc.\(doc.id.uuidString)")
                        }
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("SP-53.queue.row")
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Menu {
                    Button(L10n.filterAll) { memberFilter = nil }
                    ForEach(app.members) { m in
                        Button(m.displayName) { memberFilter = m.id }
                    }
                } label: {
                    Text(memberFilter.flatMap { id in app.members.first(where: { $0.id == id })?.displayName }
                         ?? L10n.filterAll)
                        .font(.caption).padding(.horizontal, 10).frame(minHeight: 44)
                        .background(Capsule().fill(Color(.systemGray5)))
                }
                ForEach([(0, L10n.filterAll), (1, L10n.filter3d), (2, L10n.filter72h)], id: \.0) { tag, name in
                    Button(name) { windowFilter = tag }
                        .font(.caption).padding(.horizontal, 10).frame(minHeight: 44)
                        .background(Capsule().fill(windowFilter == tag ? Color("brand-primary", bundle: .main).opacity(0.2) : Color(.systemGray5)))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.thinMaterial)
        }
        .navigationTitle(L10n.ocrQueueTitle)
        .task(id: "\(app.members.map(\.id))-\(docs.pendingVersion)") { await load() }
    }

    private func load() async {
        loading = true
        await docs.loadPending(patientIds: app.members.map(\.id))
        loading = false
    }

    private func windowMatch(_ doc: DocumentStore.DocumentRow) -> Bool {
        switch windowFilter {
        case 1:
            // DST 纪律 + 单一 Domain 出口（第四轮全仓审查修复：原固定
            // -3*86400 秒与 HomeView 的日历日口径在 DST 切换日分歧 ±1 小时）
            return PendingOcrRules.isWithinLastDays(3, createdAt: doc.createdAt)
        case 2:
            return PendingOcrRules.isOverdue(createdAt: doc.createdAt)
        default:
            return true
        }
    }
}
