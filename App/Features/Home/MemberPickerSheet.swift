import SwiftUI
import Domain
import Perception

/// FR2.1① 成员切换抽屉（SP-05 切片，2026-09-26 原子结构轮第三批：自
/// HomeView 迁出）：半屏 BottomSheet，当前成员打勾。
struct MemberPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                List(app.members) { member in
                    Button {
                        app.setCurrentPatient(member.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName).font(.body)
                                Text(L10n.memberRelationDisplayName(member.relation))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member.id == app.currentPatientId {
                                Image(systemName: "checkmark").foregroundStyle(Color("brand-primary", bundle: .main))
                            }
                        }
                    }
                    .accessibilityIdentifier("SP-05.member.\(member.id.uuidString)")
                }
                .navigationTitle(L10n.homeMemberSwitch)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.member_add) {
                            dismiss()
                            // 添加家人（FR3.7 入口）：去成员管理页
                            router.navigate(to: .memberList)
                        }
                    }
                }
            }
        }
    }
}
