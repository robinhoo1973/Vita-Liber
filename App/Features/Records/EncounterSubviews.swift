import SwiftUI
import Domain
import Infrastructure
import Perception

// MARK: - 就诊子视图（2026-09-26 原子结构轮第三批：自 EncounterViews.swift 迁出）
//
// 业主组合纪律（2026-09-16）：复杂类必须由专注小类组合。EncounterViews.swift
// 原 777 行 / 6 类型——本文件承接总结页、表单与路由详情三个独立入口视图
//（各持 Environment 与自身 @State，互不依赖 EncounterViews 内的私有成员）。

/// 就诊总结页（FR4.3）：已完成/待完成检查、新增药品、复诊时间、
/// 「以下信息尚未经你确认」清单（BR-003 红点标记）
struct EncounterSummaryView: View {
    let encounter: EncounterStore.EncounterRow
    @Environment(EncountersState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var unconfirmed: [(documentId: UUID, title: String)] = []

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                List {
                    Section(L10n.encounterSummaryHeader) {
                        Text(encounter.hospital ?? L10n.encounterUntitled).font(.headline)
                        Text(encounter.date.formatted(date: .long, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let followUp = encounter.followUpRequirement {
                        Section(L10n.encounterFollowUp) {
                            Text(followUp)
                        }
                    }
                    Section(L10n.encounterSummaryUnconfirmed) {
                        if unconfirmed.isEmpty {
                            Text(L10n.encounterSummaryAllConfirmed)
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            // BR-003：未确认清单红点标记，确认前不进入确定性陈述
                            ForEach(unconfirmed, id: \.documentId) { item in
                                HStack {
                                    Image(systemName: "circle.fill").font(.caption2)
                                        .foregroundStyle(Color("semantic-danger", bundle: .main))
                                    // 审查修复（F-A4-04）：此前渲染 `documentId.uuidString
                                    // .prefix(8)`（内部 UUID 片段当资料名）与一个恒为 1 的
                                    // 假字段数。改为资料标题（空标题回落「未命名资料」）。
                                    Text(L10n.encounterSummaryDocFields(L10n.docTitle(item.title)))
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                    Section(L10n.encounterSummaryNote) {
                        Text(L10n.encounterSummaryNoteText)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)   // ui-ux §3.0 surface/tint：渐变画布透出
                .tintedCanvas()   // 渐变直挂本容器（根级背景会被 TabView/导航栈系统底色覆盖，V4.06 修正）
                .navigationTitle(L10n.encounterSummaryTitle)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.commonCancel) { dismiss() }
                    }
                }
                .task {
                    unconfirmed = await state.unconfirmedFields(patientId: encounter.patientId)
                }
            }
        }
    }
}

/// 就诊表单（FR4.1 字段全集；FR4.4 可从孤立资料懒创建——入口传资料上下文）
struct EncounterFormView: View {
    @Environment(AppState.self) private var app
    @Environment(EncountersState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var kind = EncounterKind.outpatient.rawValue
    @State private var hospital = ""
    @State private var department = ""
    @State private var doctor = ""
    @State private var chiefComplaint = ""
    @State private var diagnosisText = ""
    @State private var adviceText = ""
    @State private var followUpRequirement = ""
    @State private var feeText = ""
    // v25 叙事列（§C.1）：原文录入，不摘要不改写；过敏史仅为病历原文（资料建议 D4 另走确认流）
    @State private var presentIllness = ""
    @State private var pastHistory = ""
    @State private var physicalExam = ""
    @State private var allergyHistory = ""
    @State private var visitSummary = ""
    @State private var saveFailed = false

    private let kinds = EncounterKind.allCases

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    Section(L10n.encounterFormBasic) {
                        Picker(L10n.encounterFormKind, selection: $kind) {
                            ForEach(kinds, id: \.rawValue) { Text(L10n.encounterKindName($0)) }
                        }
                        DatePicker(L10n.encounterFormDate, selection: $date)
                        TextField(L10n.encounterFormHospital, text: $hospital)
                        TextField(L10n.encounterFormDepartment, text: $department)
                        TextField(L10n.encounterFormDoctor, text: $doctor)
                    }
                    Section(L10n.encounterFormClinical) {
                        TextField(L10n.encounterFormComplaint, text: $chiefComplaint, axis: .vertical)
                        TextField(L10n.encounterFormDiagnosis, text: $diagnosisText, axis: .vertical)
                        TextField(L10n.encounterFormAdvice, text: $adviceText, axis: .vertical)
                        TextField(L10n.encounterFormFollowUp, text: $followUpRequirement, axis: .vertical)
                        TextField(L10n.encounterFormFee, text: $feeText)
                            .keyboardType(.decimalPad)
                    }
                    Section(L10n.encounterNarrative) {
                        TextField(DocumentsDisplay.fieldLabel(forKey: "present_illness"), text: $presentIllness, axis: .vertical)
                            .accessibilityIdentifier("SP-08.encounter.form.present_illness")
                        TextField(DocumentsDisplay.fieldLabel(forKey: "past_history"), text: $pastHistory, axis: .vertical)
                            .accessibilityIdentifier("SP-08.encounter.form.past_history")
                        TextField(DocumentsDisplay.fieldLabel(forKey: "physical_exam"), text: $physicalExam, axis: .vertical)
                            .accessibilityIdentifier("SP-08.encounter.form.physical_exam")
                        TextField(DocumentsDisplay.fieldLabel(forKey: "allergy_history"), text: $allergyHistory, axis: .vertical)
                            .accessibilityIdentifier("SP-08.encounter.form.allergy_history")
                        TextField(DocumentsDisplay.fieldLabel(forKey: "visit_summary"), text: $visitSummary, axis: .vertical)
                            .accessibilityIdentifier("SP-08.encounter.form.visit_summary")
                    }
                }
                .navigationTitle(L10n.encounterFormTitle)
                .saveFailedAlert(title: L10n.encounterSaveFailed,
                                 hint: L10n.encounterSaveFailedHint,
                                 isPresented: $saveFailed)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.commonCancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.reminder_save) {
                            let draft = EncounterDraft(
                                patientId: app.currentPatientId, date: date, kind: kind,
                                hospital: hospital.isEmpty ? nil : hospital,
                                department: department.isEmpty ? nil : department,
                                doctor: doctor.isEmpty ? nil : doctor,
                                chiefComplaint: chiefComplaint.isEmpty ? nil : chiefComplaint,
                                diagnosisText: diagnosisText.isEmpty ? nil : diagnosisText,
                                adviceText: adviceText.isEmpty ? nil : adviceText,
                                followUpRequirement: followUpRequirement.isEmpty ? nil : followUpRequirement,
                                feeAmount: Double(feeText),
                                presentIllness: presentIllness.isEmpty ? nil : presentIllness,
                                visitSummary: visitSummary.isEmpty ? nil : visitSummary,
                                pastHistory: pastHistory.isEmpty ? nil : pastHistory,
                                physicalExam: physicalExam.isEmpty ? nil : physicalExam,
                                allergyHistory: allergyHistory.isEmpty ? nil : allergyHistory)
                            Task {
                                // 保存失败保留表单并提示可重试——此前 upsert 吞错后
                                // 无条件 dismiss，失败呈现为「已保存」而数据丢失
                                if await state.upsert(draft) {
                                    dismiss()
                                } else {
                                    saveFailed = true
                                }
                            }
                        }
                        .accessibilityIdentifier("SP-08.encounter.form.save")
                    }
                }
            }
        }
    }
}

/// §5.45 路由式就诊详情（V3.72）：深链/通知指向就诊时按 id 从
/// EncountersState 投影查找并渲染详情；查无（已删除）回落可见降级。
struct EncounterDetailRouteView: View {
    let encounterId: UUID
    @Environment(EncountersState.self) private var state
    /// 深链冷启动投影未加载时按 id 直取（跨成员可见，路由成员即就诊成员）
    @State private var direct: EncounterStore.EncounterRow?

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let enc = state.encounters.first(where: { $0.id == encounterId }) ?? direct {
                    EncounterDetailView(encounter: enc)
                } else {
                    RouteFallbackView(route: .encounterDetail(encounterId))
                }
            }
            .task {
                // 此前视图从不加载：冷启动深链恒渲染「该资料已不存在」并自动弹回
                if state.encounters.first(where: { $0.id == encounterId }) == nil {
                    direct = await state.get(id: encounterId)
                }
            }
        }
    }
}
