#if DEBUG
import SwiftUI

/// 样张：相机拍摄屏（仅 DEBUG；2026-10-29 样张图库批）。
///
/// 演示要点：深色取景器 + 文档对齐框、闪光灯三态循环（auto/on/off，≤350ms
/// 弹簧动画）、变焦档位、快门按下 HaHaptics 冲击 + 白闪、ScreenState 驱动
/// 的「处理中」覆盖层、以及 value 式 NavigationLink 深链演示（由
/// SamplesRootView 提供 navigationDestination）。
/// 平台纪律：iOS 16 部署面——禁 iOS 17 专属 API（无 sensoryFeedback /
/// PhaseAnimator），触觉走 DS 的 Haptics 单出口，动画 ≤350ms 且只表达状态切换。
struct CameraSampleView: View {
    /// 闪光灯三态（演示值，不控真实硬件）。
    private enum FlashMode: String, CaseIterable {
        case auto, on, off

        var next: FlashMode {
            switch self {
            case .auto: return .on
            case .on: return .off
            case .off: return .auto
            }
        }

        var glyph: String {
            switch self {
            case .auto: return "bolt.badge.a"
            case .on: return "bolt.fill"
            case .off: return "bolt.slash.fill"
            }
        }

        var label: String { rawValue.capitalized }
    }

    @State private var flashMode: FlashMode = .auto
    @State private var zoom: Double = 1
    @State private var stage: TrackingStage = .active
    @State private var captureState: ScreenState<Int> = .loading
    @State private var shutterFlash = false
    @State private var showGrid = true

    private let zoomPresets: [Double] = [1, 2, 3]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            viewfinder
            VStack {
                topBar
                Spacer(minLength: 0)
                zoomPicker
                    .padding(.bottom, 18)
                bottomBar
                    .padding(.bottom, 28)
            }
        }
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { gridToggle }
        .task {
            // 模拟取景器预热：repository 演示层不参与，直接置就绪。
            try? await Task.sleep(nanoseconds: 250_000_000) // try?-ok: 演示延迟，取消即离开加载态
            captureState = .empty
        }
    }

    // MARK: - 取景器

    private var viewfinder: some View {
        ZStack {
            // 「预览画面」演示：暗色渐变 + 纸张暗示，不引入真实相机。
            RoundedRectangle(cornerRadius: 0)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .center) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(white: 0.82))
                        .frame(width: 190, height: 250)
                        .rotationEffect(.degrees(-3))
                        .overlay(paperLines)
                        .opacity(0.35)
                }
            if showGrid { gridOverlay }
            ScanBracketShape(inset: 22, length: 34)
                .stroke(Color.white.opacity(0.9),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(34)
            Text("Align the document within the frame")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.35), in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
            if case .loading = captureState {
                loadingOverlay
            }
        }
        .overlay {
            // 快门白闪：只在按下瞬间，一次淡出（状态切换表达，非装饰）。
            Color.white
                .opacity(shutterFlash ? 0.85 : 0)
                .animation(.easeOut(duration: 0.18), value: shutterFlash)
                .allowsHitTesting(false)
        }
    }

    private var paperLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<6, id: \.self) { row in
                Capsule()
                    .fill(Color(white: 0.45))
                    .frame(width: row == 0 ? 90 : 150, height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var gridOverlay: some View {
        GeometryReader { proxy in
            Path { path in
                for step in 1...2 {
                    let x = proxy.size.width * CGFloat(step) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    let y = proxy.size.height * CGFloat(step) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text("Preparing camera…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(18)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: VLCornerRadius.compact))
    }

    // MARK: - 顶栏 / 变焦 / 底栏

    private var topBar: some View {
        HStack(spacing: 14) {
            circleControl(glyph: flashMode.glyph,
                          identifier: "sample.camera.flash") {
                withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                    flashMode = flashMode.next
                }
                Haptics.impact(.light)
            }
            PillBadge(text: flashMode.label, style: .neutral, size: .small)
                .accessibilityLabel("Flash mode \(flashMode.label)")
            Spacer()
            PillBadge(text: stage.title, style: stage == .active ? .brand : .neutral)
                .accessibilityLabel("Camera state \(stage.title)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var zoomPicker: some View {
        HStack(spacing: 8) {
            ForEach(zoomPresets, id: \.self) { preset in
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.3)) { zoom = preset }
                    Haptics.impact(.light)
                } label: {
                    Text("\(Int(preset))×")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(zoom == preset ? .black : .white)
                        .frame(width: 44, height: 32)
                        .background(zoom == preset ? Color.yellow : Color.white.opacity(0.16),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sample.camera.zoom.\(Int(preset))")
                .accessibilityLabel("Zoom \(Int(preset)) times")
            }
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button {
                stage = stage == .active ? .paused : .active
            } label: {
                circleControlLabel(glyph: stage == .active ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sample.camera.stage")
            .accessibilityLabel(stage == .active ? "Pause camera" : "Resume camera")

            Spacer()

            captureButton

            Spacer()

            NavigationLink(value: SamplesRoute.dashboard) {
                circleControlLabel(glyph: "square.grid.2x2")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sample.camera.deeplink.dashboard")
            .accessibilityLabel("Open dashboard sample")
        }
        .padding(.horizontal, 36)
    }

    private var captureButton: some View {
        Button(action: capture) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                Circle()
                    .fill(Color.white)
                    .frame(width: 58, height: 58)
                if case .loaded(let count) = captureState, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.black.opacity(0.7))
                        .offset(y: -2)
                }
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(captureState.isLoading)
        .accessibilityIdentifier("sample.camera.shutter")
        .accessibilityLabel("Capture page")
    }

    private func circleControl(glyph: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circleControlLabel(glyph: glyph)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("Toggle flash")
    }

    private func circleControlLabel(glyph: String) -> some View {
        Image(systemName: glyph)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.16), in: Circle())
    }

    @ToolbarContentBuilder
    private var gridToggle: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showGrid.toggle()
            } label: {
                Image(systemName: showGrid ? "grid" : "rectangle.dashed")
            }
            .accessibilityIdentifier("sample.camera.grid")
            .accessibilityLabel(showGrid ? "Hide grid" : "Show grid")
        }
    }

    private func capture() {
        Haptics.impact(.heavy)
        shutterFlash = true
        captureState = .loading
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000) // try?-ok: 演示快门处理延迟
            shutterFlash = false
            switch captureState {
            case .loaded(let count):
                captureState = .loaded(count + 1)
            default:
                captureState = .loaded(1)
            }
        }
    }
}

/// 文档对齐角框（四角括号）：Path 内置四段折线，圆头线帽。
struct ScanBracketShape: Shape {
    var inset: CGFloat
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            // (角点, 横向端点, 纵向端点)
            (CGPoint(x: rect.minX + inset, y: rect.minY + inset),
             CGPoint(x: rect.minX + inset + length, y: rect.minY + inset),
             CGPoint(x: rect.minX + inset, y: rect.minY + inset + length)),
            (CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
             CGPoint(x: rect.maxX - inset - length, y: rect.minY + inset),
             CGPoint(x: rect.maxX - inset, y: rect.minY + inset + length)),
            (CGPoint(x: rect.minX + inset, y: rect.maxY - inset),
             CGPoint(x: rect.minX + inset + length, y: rect.maxY - inset),
             CGPoint(x: rect.minX + inset, y: rect.maxY - inset - length)),
            (CGPoint(x: rect.maxX - inset, y: rect.maxY - inset),
             CGPoint(x: rect.maxX - inset - length, y: rect.maxY - inset),
             CGPoint(x: rect.maxX - inset, y: rect.maxY - inset - length)),
        ]
        for (corner, horizontal, vertical) in corners {
            path.move(to: horizontal)
            path.addLine(to: corner)
            path.addLine(to: vertical)
        }
        return path
    }
}

#Preview("Camera") {
    NavigationStack {
        CameraSampleView()
    }
}
#endif
