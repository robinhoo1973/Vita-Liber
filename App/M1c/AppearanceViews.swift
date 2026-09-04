import SwiftUI
import Domain   // AppSettingKey / AppSettings 值类型

/// FR14.4 外观主题三态（tech-spec §5.28.1 定义；ui-ux §5.12.1 交互）。
/// ColorScheme 映射必须在 App 层——Domain 纯净规则禁止 import SwiftUI（L0 [5/11] 白名单）。
enum AppTheme: String, Codable, CaseIterable, Sendable {
    case light, dark, system

    /// nil = 跟随系统（注入点：根视图 `.preferredColorScheme(theme.colorScheme)`）
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

/// FR18.16 叠加规则（纯函数）：高对比度有效 = 手动开启 OR 关怀模式。
/// 关怀模式退出后自动回落用户此前的手动选择（不落盘改写 highContrastEnabled）。
enum AppearanceRules {
    static func highContrastEffective(highContrastEnabled: Bool, careMode: Bool) -> Bool {
        highContrastEnabled || careMode
    }
}

/// ui-ux §5.12.1 外观与主题选择器：水平三段 + 迷你预览色块，即时生效、无确认弹窗。
/// 预览语义（mock me.html `.theme-preview`）：浅=白底黑条 / 深=黑底白条 / 跟随=半白半黑。
/// FR14.4 外观与主题设置页（SP-25 子页路由落点）：三段选择器 + 高对比度开关。
/// 切换即时生效（AppRootView 读 settings 注入 preferredColorScheme/contrast）。
struct ThemeSettingsView: View {
    @Environment(AppSettingsStore.self) private var settings
    @Environment(AppState.self) private var app

    var body: some View {
        Form {
            Section {
                ThemeSegmentedPicker(selection: themeBinding)
            } footer: {
                Text(L10n.settings_themeHint)
            }
            Section {
                Toggle(L10n.settings_highContrast, isOn: highContrastBinding)
            } footer: {
                Text(L10n.settings_highContrastFooter)
            }
        }
        .navigationTitle(L10n.settings_appearance)
        .task { await settings.load() }
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: {
                AppTheme(rawValue: settings.values[.appearance]
                         ?? AppSettingKey.appearance.defaultValue) ?? .system
            },
            set: { theme in
                Task { await settings.set(theme.rawValue, for: .appearance) }
            })
    }

    private var highContrastBinding: Binding<Bool> {
        Binding(
            get: { settings.values[.highContrastEnabled] == "true" },
            set: { on in
                Task { await settings.set(on ? "true" : "false", for: .highContrastEnabled) }
            })
    }
}

struct ThemeSegmentedPicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppTheme.allCases, id: \.self) { theme in
                segment(for: theme)
            }
        }
        .padding(4)
        .background(Color("bg-grouped", bundle: .main),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func segment(for theme: AppTheme) -> some View {
        let selected = theme == selection
        return Button {
            selection = theme
        } label: {
            VStack(spacing: 6) {
                ThemePreviewSwatch(theme: theme)
                    .frame(width: 44, height: 24)
                Text(label(theme))
                    .font(.caption)
                    .foregroundStyle(selected
                                     ? Color("brand-primary", bundle: .main)
                                     : Color("text-secondary", bundle: .main))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                selected
                    ? Color("brand-primary", bundle: .main).opacity(0.12)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SP-25.setting.appearance.\(theme.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func label(_ theme: AppTheme) -> String {
        switch theme {
        case .light: return L10n.settings_themeLight
        case .dark: return L10n.settings_themeDark
        case .system: return L10n.settings_themeSystem
        }
    }
}

/// 迷你预览色块（FR14.4 三态可视区分）
struct ThemePreviewSwatch: View {
    let theme: AppTheme

    var body: some View {
        switch theme {
        case .light:
            swatch(background: Color.white, bar: Color.black)
        case .dark:
            swatch(background: Color.black, bar: Color.white)
        case .system:
            HStack(spacing: 0) {
                Rectangle().fill(Color.white)
                Rectangle().fill(Color.black)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
        }
    }

    private func swatch(background: Color, bar: Color) -> some View {
        Rectangle()
            .fill(background)
            .overlay(
                VStack(spacing: 3) {
                    Rectangle().fill(bar.opacity(0.85)).frame(height: 2.5)
                    Rectangle().fill(bar.opacity(0.45)).frame(height: 2.5)
                    Rectangle().fill(bar.opacity(0.45)).frame(width: 18, height: 2.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
    }
}
