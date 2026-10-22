import SwiftUI
import Domain
import Perception

/// 健康档案总览（SP-49 家族入口，2026-10-22）。
///
/// 首页「档案完善进度」与「我的 › 个人档案」统一落到这里：
/// 基本信息、慢性病、手术史、过敏、当前用药各有一个明确入口。
/// 所有入口都只读/记录用户自报事实，不做诊断或症状推断。
struct HealthHistoryHubView: View {
    @Environment(AppState.self) private var app

    private var member: PatientProfile? {
        app.members.first {
            $0.id == app.currentPatientId && $0.deletedAt == nil
        }
    }

    private var progress: (done: Int, total: Int)? {
        app.profileCompletion
    }

    var body: some View {
        WithPerceptionTracking {
            List {
                if let member {
                    Section {
                        header(member)
                    }
                }

                Section(L10n.hub_healthRecords) {
                    NavigationLink {
                        HealthProblemListView(initialKind: "chronic")
                    } label: {
                        row(title: L10n.healthHistoryChronic,
                            subtitle: L10n.healthHistoryChronicHint,
                            systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("SP-49.hub.chronic")

                    NavigationLink {
                        HealthProblemListView(initialKind: "surgery")
                    } label: {
                        row(title: L10n.healthHistorySurgery,
                            subtitle: L10n.healthHistorySurgeryHint,
                            systemImage: "bandage")
                    }
                    .accessibilityIdentifier("SP-49.hub.surgery")
                }

                Section {
                    NavigationLink {
                        AllergyListView()
                    } label: {
                        row(title: L10n.allergyTitle,
                            subtitle: L10n.healthHistoryAllergyHint,
                            systemImage: "allergens")
                    }
                    .accessibilityIdentifier("SP-49.hub.allergy")

                    NavigationLink {
                        MedicationPlanListView()
                    } label: {
                        row(title: L10n.planListTitle,
                            subtitle: L10n.healthHistoryMedicationHint,
                            systemImage: "pills")
                    }
                    .accessibilityIdentifier("SP-49.hub.medication")

                    NavigationLink {
                        ImmunizationHubView()
                    } label: {
                        row(title: L10n.immunization_title,
                            subtitle: L10n.healthHistoryVaccineHint,
                            systemImage: "syringe")
                    }
                    .accessibilityIdentifier("SP-49.hub.immunization")
                }

                if let member {
                    Section(L10n.memberDetailBasic) {
                        NavigationLink {
                            MemberDetailView(member: member)
                        } label: {
                            LabeledContent(L10n.memberDetailBasic,
                                           value: member.displayName)
                        }
                        .accessibilityIdentifier("SP-49.hub.basic")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .tintedCanvas()
            .navigationTitle(L10n.hub_healthRecords)
        }
    }

    private func header(_ member: PatientProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.text.rectangle")
                    .font(.title2)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                    .frame(width: 40, height: 40)
                    .background(Color("brand-primary", bundle: .main).opacity(0.12),
                                in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(.headline)
                    Text(L10n.memberRelationDisplayName(member.relation))
                        .font(.caption)
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                }
                Spacer()
            }
            if let progress {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(Color("brand-primary", bundle: .main))
                Text(L10n.homeProfileProgressFmt(progress.done, progress.total))
                    .font(.caption)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SP-49.hub.header")
    }

    private func row(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color("brand-primary", bundle: .main))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
            }
        }
        .padding(.vertical, 2)
    }
}
