import SwiftUI
import Domain

/// F22 帮助与关于（M1c 滞留清偿）：SP-47 条款入口 + 免责声明 + 版本。
struct HelpAboutView: View {
    var body: some View {
        Form {
            Section("关于") {
                Text("Vita Liber · 青囊书")
                Text("版本 1.0.0（构建自源码）")
                Text("个人医疗资料的归档与提醒工具")
            }
            Section("法律与免责声明") {
                Text("本 App 不是医疗设备：不下诊断、不给治疗方案建议、不替代医生。紧急情况请直接拨打 120 或前往医院。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("隐私政策与服务条款（SP-47）") {
                    Text("隐私政策与服务条款全文（M1.5 接入正式文本与版本号/生效日期）")
                        .padding()
                        .accessibilityIdentifier("SP-47.terms.body")
                }
                .accessibilityIdentifier("SP-47.terms.entry")
            }
            Section("帮助") {
                Text("常见问题与使用引导（HelpContentIndex 随 M1.5 后批接入）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("帮助与关于")
    }
}
