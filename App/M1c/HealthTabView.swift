import SwiftUI
import Domain
import Perception

/// H（2026-09-14）：健康 Tab——替代原 AI Tab，聚焦 HealthKit 数据摘要、趋势概览、搜索入口。
/// FR3.1 Tab 重构：sparkles → heart.text.clipboard；offline-first，零 OpenAI 依赖。
struct HealthTabView: View {
    @Environment(AppState.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var searchText = ""

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                LazyVStack(spacing: 16) {
                    // 搜索栏
                    searchBar
                    // HealthKit 数据卡片
                    healthSummarySection
                    // 快捷操作
                    quickActionsSection
                }
                .padding(16)
            }
            .navigationTitle(L10n.navHealth)
            .searchable(text: $searchText, prompt: Text(L10n.healthSearchPrompt))
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.healthSearchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - HealthKit 摘要

    private var healthSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.healthSummaryTitle)
                .font(.headline)
            // TODO: 接入 HealthKit 数据卡片（HealthSummaryView 或 DeviceConnectionView 摘要）
            // 当前占位：提示连接设备
            VStack(spacing: 8) {
                Image(systemName: "heart.text.clipboard")
                    .font(.largeTitle)
                    .foregroundStyle(.red.opacity(0.6))
                Text(L10n.healthConnectDevice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    router.navigate(to: .deviceConnection)
                } label: {
                    Text(L10n.healthConnectButton)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - 快捷操作

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.healthQuickActions)
                .font(.headline)
            HStack(spacing: 12) {
                quickActionCard(icon: "waveform.path.ecg", title: L10n.healthTrends, color: .blue) {
                    // TODO: 跳转趋势图表
                }
                quickActionCard(icon: "bell.badge", title: L10n.healthReminders, color: .orange) {
                    router.navigate(to: .reminders)
                }
                quickActionCard(icon: "doc.text.magnifyingglass", title: L10n.healthSearchRecords, color: .green) {
                    router.navigate(to: .records)
                }
            }
        }
    }

    private func quickActionCard(icon: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
