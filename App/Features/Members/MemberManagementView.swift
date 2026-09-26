import SwiftUI
import Domain
import Perception

/// F3 成员管理（SP-06 切片）：列表/切换/添加家人（FR3.7）。
///
/// 配额判定在 Domain（`PaywallRules.addingMemberWouldExceed`）——视图只在
/// 「会超配额」时走五时机弹墙（comercial §3 memberQuotaReached），
/// Pro 已解锁则不弹；业务规则零散落视图（tech-spec §1.1 规则 4）。
struct MemberManagementView: View {
    @Environment(AppState.self) private var app
    @Environment(AppEntitlementStore.self) private var entitlements
    @State private var showAdd = false
    @State private var quotaHint: String?
    /// 审查修正（F-A1）：addMember 写库失败此前静默关单（quotaHint=nil → 无警报）——
    /// 用户以为已添加而记录实际缺失（四态纪律：写失败必须可见）。
    @State private var addFailed = false

    var body: some View {
        WithPerceptionTracking {
            List {
                Section {
                    ForEach(app.members) { member in
                        // ForEach 行闭包逃逸：行内同步读感知对象属性，须自行包裹（子项目 I）
                        WithPerceptionTracking {
                            HStack {
                                memberIcon(member.relation).resizable().frame(width: 24, height: 24)
                                    .accessibilityLabel(memberIconLabel(member.relation))
                                NavigationLink {
                                    MemberDetailView(member: member)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(member.displayName).font(.subheadline)
                                        Text(L10n.memberRelationDisplayName(member.relation))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if member.id == app.currentPatientId {
                                    Text(L10n.member_current).font(.caption).bold()
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(Color("brand-primary", bundle: .main).opacity(0.15)))
                                        .foregroundStyle(Color("brand-primary", bundle: .main))
                                } else {
                                    Button(L10n.member_switch) {
                                        app.setCurrentPatient(member.id)
                                    }
                                    .font(.caption)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("FR3.7.member.switch")
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("FR3.7.member.row")
                        }
                    }
                } footer: {
                    Text(L10n.member_quotaHint)
                }
                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label(L10n.member_add, systemImage: "person.badge.plus").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("FR3.7.member.add")
                }
            }
            .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
            .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
            .navigationTitle(L10n.member_title)
            .task { await app.loadMembers() }
            .sheet(isPresented: $showAdd) {
                MemberCreateSheet { name, relation, birthDate in
                    Task { @MainActor in
                        // 五时机 memberQuotaReached（Domain 判定 + 弹墙调度 + 24h 频控）。
                        // 评审修正：闸门与弹墙解耦——放行只看「额度未超 或 已持 Pro」，
                        // evaluateTrigger 仅决定墙弹不弹（24h 频控不得成为放行通道）
                        if PaywallRules.memberAdditionBlocked(
                            currentCount: app.members.count,
                            ownedProducts: entitlements.owned) {
                            // 评审修正第二轮：弹墙被 24h 频控抑制时不得静默关单——
                            // 回落为列表内常驻配额提示（用户至少知道为什么没加上）
                            if !entitlements.evaluateTrigger(.memberQuotaReached) {
                                quotaHint = L10n.member_quotaHint
                            }
                            showAdd = false
                            return
                        }
                        let ok = await app.addMember(name: name, relation: relation, birthDate: birthDate)
                        if ok {
                            quotaHint = L10n.member_addedHint
                        } else {
                            addFailed = true   // 写库失败：关单前弹失败警报，不得静默
                        }
                        showAdd = false
                    }
                }
            }
            .alert(quotaHint ?? L10n.member_addedHint, isPresented: Binding(
                get: { quotaHint != nil },
                set: { if !$0 { quotaHint = nil } })) {
                Button(L10n.onboard_gotIt, role: .cancel) {}
            }
            .alert(L10n.member_addFailed, isPresented: $addFailed) {
                Button(L10n.onboard_gotIt, role: .cancel) {}
            }
        }
    }
}

extension MemberManagementView {
    /// 按关系选图标（FR3.1 关系枚举：本人/配偶/子女/父母/祖父母/其他）。
    /// 审查修复：sheet 只提供粗粒度关系（子女/父母/祖父母/其他），原映射
    /// 只覆盖细粒度（父亲/母亲/儿子/女儿）——粗粒度全部回落通用家庭图标。
    /// 无专属资产的关系用 SF Symbols 兜底 + 无障碍标签，不留空、不误导。
    private func memberIcon(_ relation: String) -> Image {
        // 结构轮 2026-09-15：词表单点 = Domain `MemberRelation`（此前中文串 switch
        // 硬编码在视图，与 sheet 词表/删除闸门显示串比较同源——漂移即静默错图标/失效闸门）。
        switch MemberRelation(tolerant: relation) {
        case .partner: return VLIcon.memberPartner
        case .father: return VLIcon.memberFather
        case .mother: return VLIcon.memberMother
        case .son: return VLIcon.memberSon
        case .daughter: return VLIcon.memberDaughter
        case .selfMember: return VLIcon.memberSelf
        case .child: return Image(systemName: "figure.child")
        case .parent: return Image(systemName: "figure.2.arms.open")
        case .grandparent: return Image(systemName: "figure.2")
        case .other: return Image(systemName: "person.crop.circle")
        }
    }

    /// 图标无障碍标签（VoiceOver 读出关系语义，而非「图标」；
    /// 单一出口 = L10n.memberRelationDisplayName，细粒度关系同样本地化）
    private func memberIconLabel(_ relation: String) -> String {
        L10n.memberRelationDisplayName(relation)
    }
}
