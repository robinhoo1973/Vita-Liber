import SwiftUI
import Domain

/// 人体图基础几何与解剖示意（2026-10-24 第三版）。
///
/// 二级部位层改用项目内 CC0 全身剪影 `anatomy-body-front` 的局部放大，
/// 取代旧版手绘圆角矩形/椭圆「区域轮廓」——旧轮廓与真实人体比例不符，
/// 放大后可见明显廉价感。剪影作为淡色解剖参照，器官插图仍取 Servier
/// Medical Art（CC BY 4.0）的专业插图；只做「已确诊病名 / 已发生手术」的
/// 定位索引，不做症状判断或诊断推断。
enum AnatomyBodySide: String, CaseIterable, Identifiable {
    case front
    case back

    var id: String { rawValue }
    var title: String {
        self == .front ? L10n.healthHistoryFront : L10n.healthHistoryBack
    }
}

/// 全身剪影（1516×3438 PDF）的归一化坐标与区域放大换算。
enum BodySilhouette {
    /// 资源原始宽高比（与 `anatomy-body-front.pdf` 一致）。
    static let aspectRatio: CGFloat = 1516.0 / 3438.0

    /// 二级部位在全身剪影上的归一化裁切窗口。
    /// 盆腔/腹部窗口按人体比例收窄，避免旧版「整块圆角矩形」的失真。
    static func crop(for regionID: String) -> CGRect? {
        switch regionID {
        case "head_neck":
            return CGRect(x: 0.355, y: 0.005, width: 0.290, height: 0.185)
        case "chest":
            return CGRect(x: 0.235, y: 0.135, width: 0.530, height: 0.290)
        case "abdomen":
            return CGRect(x: 0.275, y: 0.385, width: 0.450, height: 0.215)
        case "pelvis":
            return CGRect(x: 0.300, y: 0.555, width: 0.400, height: 0.175)
        case "back":
            return CGRect(x: 0.235, y: 0.135, width: 0.530, height: 0.465)
        case "upper_limb":
            return CGRect(x: 0.015, y: 0.130, width: 0.285, height: 0.470)
        case "lower_limb":
            return CGRect(x: 0.315, y: 0.555, width: 0.225, height: 0.430)
        default:
            return nil
        }
    }

    /// 裁切窗口铺满视图所需的图片尺寸与偏移（等比，居中裁切）。
    struct Layout {
        let imageWidth: CGFloat
        let imageHeight: CGFloat
        let originX: CGFloat
        let originY: CGFloat
    }

    static func layout(crop: CGRect, in size: CGSize) -> Layout {
        guard crop.width > 0, crop.height > 0 else {
            return Layout(imageWidth: size.width, imageHeight: size.height,
                          originX: 0, originY: 0)
        }
        // 以高度铺满 = 完整展示所选部位，不裁掉肩/髋/足；人体窄于卡片，
        // 左右留白由渐变卡片承接，比旧版「拉伸成卡片形状」更接近解剖比例。
        let imageHeight = size.height / crop.height
        let imageWidth = imageHeight * aspectRatio
        let originX = (size.width - crop.width * imageWidth) / 2 - crop.minX * imageWidth
        let originY = -crop.minY * imageHeight
        return Layout(imageWidth: imageWidth, imageHeight: imageHeight,
                      originX: originX, originY: originY)
    }

    /// 裁切窗口在视图坐标系中的实际矩形（器官热点按同一矩形换算）。
    static func displayedCrop(_ crop: CGRect, layout: Layout) -> CGRect {
        CGRect(x: layout.originX + crop.minX * layout.imageWidth,
               y: layout.originY + crop.minY * layout.imageHeight,
               width: crop.width * layout.imageWidth,
               height: crop.height * layout.imageHeight)
    }
}

/// 二级部位背景：全身剪影的局部放大（模板着色，随深浅色主题）。
struct BodySilhouetteBackdrop: View {
    let regionID: String

    var body: some View {
        GeometryReader { geo in
            if let crop = BodySilhouette.crop(for: regionID) {
                let layout = BodySilhouette.layout(crop: crop, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image("anatomy-body-front")
                        .resizable()
                        .renderingMode(.template)
                        .interpolation(.high)
                        .antialiased(true)
                        .foregroundStyle(Color("text-primary", bundle: .main).opacity(0.13))
                        .frame(width: layout.imageWidth, height: layout.imageHeight)
                        .offset(x: layout.originX, y: layout.originY)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
