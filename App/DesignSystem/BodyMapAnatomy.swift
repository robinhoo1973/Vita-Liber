import SwiftUI
import Domain

/// 人体图基础几何与解剖示意（2026-10-22 第二版）。
///
/// 纯 SwiftUI `Shape`，无第三方依赖、无网络、无位图缩放失真。
/// 只做「已确诊病名 / 已发生手术」的定位索引，不做症状判断或诊断推断。
enum AnatomyBodySide: String, CaseIterable, Identifiable {
    case front
    case back

    var id: String { rawValue }
    var title: String {
        self == .front ? L10n.healthHistoryFront : L10n.healthHistoryBack
    }
}

private enum AnatomyGeometry {
    static func point(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
}

/// 体表参考线：锁骨、胸骨、腹白线、脊柱；只做视觉引导，不是医学标注。
struct BodySurfaceDetails: Shape {
    var side: AnatomyBodySide = .front

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if side == .front {
            path.move(to: AnatomyGeometry.point(rect, 0.405, 0.267))
            path.addQuadCurve(to: AnatomyGeometry.point(rect, 0.492, 0.252),
                              control: AnatomyGeometry.point(rect, 0.448, 0.240))
            path.move(to: AnatomyGeometry.point(rect, 0.595, 0.267))
            path.addQuadCurve(to: AnatomyGeometry.point(rect, 0.508, 0.252),
                              control: AnatomyGeometry.point(rect, 0.552, 0.240))
            path.move(to: AnatomyGeometry.point(rect, 0.500, 0.268))
            path.addLine(to: AnatomyGeometry.point(rect, 0.500, 0.380))
            path.move(to: AnatomyGeometry.point(rect, 0.412, 0.455))
            path.addQuadCurve(to: AnatomyGeometry.point(rect, 0.500, 0.470),
                              control: AnatomyGeometry.point(rect, 0.455, 0.474))
            path.addQuadCurve(to: AnatomyGeometry.point(rect, 0.588, 0.455),
                              control: AnatomyGeometry.point(rect, 0.545, 0.474))
            path.addEllipse(in: CGRect(x: rect.minX + 0.494 * rect.width,
                                       y: rect.minY + 0.492 * rect.height,
                                       width: 0.012 * rect.width,
                                       height: 0.012 * rect.height))
        } else {
            path.move(to: AnatomyGeometry.point(rect, 0.500, 0.240))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.500, 0.550),
                          control1: AnatomyGeometry.point(rect, 0.492, 0.340),
                          control2: AnatomyGeometry.point(rect, 0.508, 0.450))
            path.move(to: AnatomyGeometry.point(rect, 0.405, 0.280))
            path.addQuadCurve(to: AnatomyGeometry.point(rect, 0.485, 0.320),
                              control: AnatomyGeometry.point(rect, 0.430, 0.330))
            path.move(to: AnatomyGeometry.point(rect, 0.595, 0.280))
            path.addQuadCurve(to: AnatomyGeometry.point(rect, 0.515, 0.320),
                              control: AnatomyGeometry.point(rect, 0.570, 0.330))
        }
        return path
    }
}

/// 二级器官/组织的放大区域示意轮廓。
struct RegionOutlineShape: Shape {
    let regionID: String

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch regionID {
        case "head_neck":
            path.addEllipse(in: CGRect(x: rect.minX + 0.245 * rect.width,
                                       y: rect.minY + 0.035 * rect.height,
                                       width: 0.510 * rect.width,
                                       height: 0.560 * rect.height))
            path.addRoundedRect(in: CGRect(x: rect.minX + 0.405 * rect.width,
                                           y: rect.minY + 0.535 * rect.height,
                                           width: 0.190 * rect.width,
                                           height: 0.255 * rect.height),
                                cornerSize: CGSize(width: 28, height: 28))
        case "chest":
            path.move(to: AnatomyGeometry.point(rect, 0.155, 0.215))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.500, 0.060),
                          control1: AnatomyGeometry.point(rect, 0.245, 0.105),
                          control2: AnatomyGeometry.point(rect, 0.385, 0.045))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.845, 0.215),
                          control1: AnatomyGeometry.point(rect, 0.615, 0.045),
                          control2: AnatomyGeometry.point(rect, 0.755, 0.105))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.790, 0.790),
                          control1: AnatomyGeometry.point(rect, 0.855, 0.420),
                          control2: AnatomyGeometry.point(rect, 0.835, 0.640))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.500, 0.900),
                          control1: AnatomyGeometry.point(rect, 0.720, 0.880),
                          control2: AnatomyGeometry.point(rect, 0.610, 0.910))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.210, 0.790),
                          control1: AnatomyGeometry.point(rect, 0.390, 0.910),
                          control2: AnatomyGeometry.point(rect, 0.280, 0.880))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.155, 0.215),
                          control1: AnatomyGeometry.point(rect, 0.165, 0.640),
                          control2: AnatomyGeometry.point(rect, 0.145, 0.420))
            path.closeSubpath()
        case "abdomen", "back":
            path.addRoundedRect(in: CGRect(x: rect.minX + 0.150 * rect.width,
                                           y: rect.minY + 0.045 * rect.height,
                                           width: 0.700 * rect.width,
                                           height: 0.910 * rect.height),
                                cornerSize: CGSize(width: 54, height: 54))
        case "pelvis":
            path.move(to: AnatomyGeometry.point(rect, 0.240, 0.100))
            path.addLine(to: AnatomyGeometry.point(rect, 0.760, 0.100))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.630, 0.910),
                          control1: AnatomyGeometry.point(rect, 0.790, 0.480),
                          control2: AnatomyGeometry.point(rect, 0.760, 0.800))
            path.addLine(to: AnatomyGeometry.point(rect, 0.370, 0.910))
            path.addCurve(to: AnatomyGeometry.point(rect, 0.240, 0.100),
                          control1: AnatomyGeometry.point(rect, 0.240, 0.800),
                          control2: AnatomyGeometry.point(rect, 0.210, 0.480))
            path.closeSubpath()
        case "upper_limb":
            path.addRoundedRect(in: CGRect(x: rect.minX + 0.375 * rect.width,
                                           y: rect.minY + 0.040 * rect.height,
                                           width: 0.250 * rect.width,
                                           height: 0.920 * rect.height),
                                cornerSize: CGSize(width: 46, height: 46))
        case "lower_limb":
            path.addRoundedRect(in: CGRect(x: rect.minX + 0.340 * rect.width,
                                           y: rect.minY + 0.040 * rect.height,
                                           width: 0.320 * rect.width,
                                           height: 0.920 * rect.height),
                                cornerSize: CGSize(width: 52, height: 52))
        default:
            break
        }
        return path
    }
}
