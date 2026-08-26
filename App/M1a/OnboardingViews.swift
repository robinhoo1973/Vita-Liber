import SwiftUI
import Domain

/// M1a 首启流程视图：L1 三卡 → 设 PIN → 建档 → 拍摄 → OCR 确认 → 时间轴。
/// 布局对齐 ui-ux §5.29 门禁居中卡片与 §5.51 向导形态（M1c 前为规范简化版）。

struct DisclosureCardsView: View {
    @Environment(AppState.self) private var app
    let card: DisclosureCard

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 44))
                    .foregroundStyle(Color("brand-primary", bundle: .main))
                Text(title).font(.title2.bold())
            }
            .padding(.top, 32)

            Text(card.body)
                .font(.body)
                .multilineTextAlignment(.leading)
                .lineSpacing(6)
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)

            Spacer()

            Button {
                app.advanceDisclosure()
            } label: {
                Text("知道了，继续")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .accessibilityIdentifier("SP-01.disclosure.confirm")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }

    private var title: String {
        switch card.kind {
        case .boundary: return "这不是医疗设备"
        case .scope: return "数据只在本机"
        case .disclaimer: return "机器识别先确认"
        }
    }
    private var iconName: String {
        switch card.kind {
        case .boundary: return "ic-stop-octagon"
        case .scope: return "ic-lock"
        case .disclaimer: return "ic-check-circle"
        }
    }
}

/// PIN 设置与验证（SP-01 门禁卡片，§5.32 阶梯在 AppState）
struct PinEntryView: View {
    enum Mode { case setup, verify }
    @Environment(AppState.self) private var app
    let mode: Mode
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(mode == .setup ? "设置 6 位数字 PIN" : "输入 PIN 解锁")
                .font(.title2.bold())
            Text(mode == .setup ? "用于保护你的医疗资料（FR1.1）" : "错误次数过多会暂时锁定")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 1)
                        .background(Circle().fill(i < pin.count ? Color("brand-primary", bundle: .main) : .clear))
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.vertical, 12)

            Text(app.isLocked ? "已锁定，请稍后再试" : " ")
                .font(.caption)
                .foregroundStyle(.red)

            // M1a 简化键盘：系统键盘不可控于 UI 测试，用数字面板（§5.46 关怀键盘形态的雏形）
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(1...9, id: \.self) { n in key(n) }
                key(-1)   // 占位
                key(0)
                key(-2)   // 删除
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }

    @ViewBuilder
    private func key(_ n: Int) -> some View {
        Button {
            tapKey(n)
        } label: {
            if n == -2 {
                Image(systemName: "delete.left").frame(height: 52)
            } else if n == -1 {
                Color.clear.frame(height: 52)
            } else {
                Text("\(n)").font(.title3).frame(height: 52)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(n >= 0 ? "SP-01.pin.key\(n)" : "SP-01.pin.delete")
    }

    private func tapKey(_ n: Int) {
        guard !app.isLocked else { return }
        if n == -2 {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        guard n >= 0, pin.count < 6 else { return }
        pin.append("\(n)")
        guard pin.count == 6 else { return }
        if mode == .setup {
            app.setupPin(pin)
        } else {
            if !app.verifyPin(pin) { pin = "" }
        }
    }
}

struct OwnerSetupView: View {
    @Environment(AppState.self) private var app
    @State private var name = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("建立你的档案").font(.title2.bold())
            Text("资料以「本人」归属本机所有者（FR21.1）").font(.footnote).foregroundStyle(.secondary)
            TextField("你的称呼（如：王女士）", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("SP-06.owner.name")
            Button {
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                app.createOwner(name: name.trimmingCharacters(in: .whitespaces))
            } label: {
                Text("创建并继续").frame(maxWidth: 320, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("SP-06.owner.create")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }
}

struct ScanCaptureView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 24) {
            Text("拍摄处方").font(.title2.bold())
            Text("对准处方笺，自动识别边缘（F5 管线 M1a 演示态）")
                .font(.footnote).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(Color("brand-primary", bundle: .main))
                .overlay(Image(systemName: "doc.viewfinder").font(.system(size: 56)).foregroundStyle(.secondary))
                .frame(maxWidth: 320, minHeight: 240)
            Button {
                app.captureSample()
            } label: {
                Label("扫描样张（模拟）", systemImage: "camera")
                    .frame(maxWidth: 320, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("SP-07.scan.capture")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }
}

/// OCR 字段确认工作台（SP-53 待确认字段队列的 M1a 切片；BR-003 闸门）
struct OcrConfirmView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 16) {
            Text("确认识别结果").font(.title2.bold())
            Text("机器识别的字段需要你逐一确认才会生效（BR-003）")
                .font(.footnote).foregroundStyle(.secondary)

            if let set = app.activeSet {
                ForEach(set.fields) { field in
                    ConfirmFieldRowView(field: field) { app.confirmField(id: field.id) }
                }
            }

            Spacer()

            if let set = app.activeSet, set.isUsableInTimeline {
                Button {
                    app.commitToTimeline()
                } label: {
                    Text("全部确认，进入时间轴").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("SP-53.ocr.commit")
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }
}

struct ConfirmFieldRowView: View {
    let field: CandidateField
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(field.displayLabel).font(.caption).foregroundStyle(.secondary)
                Text(field.value).font(.body)
                Text(ConfidenceTier.tier(field.confidence).rawValue + "置信度")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if field.isConfirmed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("确认", action: onConfirm)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("SP-53.field.confirm.\(field.key)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(field.isConfirmed ? Color.green : Color("grade-d", bundle: .main),
                              style: StrokeStyle(lineWidth: field.isConfirmed ? 1 : 1.5, dash: field.isConfirmed ? [] : [5]))
        )
        .padding(.horizontal, 16)
    }
}

/// 时间轴最小投影（F11 M1a：仅文档一类）
struct TimelineView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 12) {
            Text("健康时间轴").font(.title2.bold())
            if app.timeline.isEmpty {
                ContentUnavailableView("还没有资料", systemImage: "clock.arrow.circlepath",
                                       description: Text("确认后的文档会出现在这里"))
            } else {
                List(app.timeline) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.body)
                        Text("已确认字段 \(entry.confirmedFieldCount)/\(entry.totalFieldCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("SP-10.timeline.entry")
                }
            }
            Button {
                app.finishOnboarding()
            } label: {
                Text("完成设置，进入应用").frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("SP-01.onboarding.finish")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("bg-grouped", bundle: .main))
    }
}
