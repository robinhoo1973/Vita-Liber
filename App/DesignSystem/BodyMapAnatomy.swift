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

    static func mirrored(_ path: Path, in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                        tx: 2 * rect.minX + rect.width, ty: 0))
    }

    static func head(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + 0.418 * rect.width,
                                   y: rect.minY + 0.018 * rect.height,
                                   width: 0.164 * rect.width,
                                   height: 0.170 * rect.height))
        // 耳廓：让轮廓不再像圆球。
        path.addEllipse(in: CGRect(x: rect.minX + 0.404 * rect.width,
                                   y: rect.minY + 0.092 * rect.height,
                                   width: 0.030 * rect.width,
                                   height: 0.048 * rect.height))
        path.addEllipse(in: CGRect(x: rect.minX + 0.566 * rect.width,
                                   y: rect.minY + 0.092 * rect.height,
                                   width: 0.030 * rect.width,
                                   height: 0.048 * rect.height))
        return path
    }

    static func neck(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(rect, 0.462, 0.166))
        path.addLine(to: point(rect, 0.538, 0.166))
        path.addCurve(to: point(rect, 0.552, 0.238),
                      control1: point(rect, 0.541, 0.190),
                      control2: point(rect, 0.548, 0.214))
        path.addLine(to: point(rect, 0.448, 0.238))
        path.addCurve(to: point(rect, 0.462, 0.166),
                      control1: point(rect, 0.452, 0.214),
                      control2: point(rect, 0.459, 0.190))
        path.closeSubpath()
        return path
    }

    static func torso(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(rect, 0.362, 0.222))
        path.addCurve(to: point(rect, 0.338, 0.300),
                      control1: point(rect, 0.345, 0.232),
                      control2: point(rect, 0.338, 0.265))
        path.addCurve(to: point(rect, 0.352, 0.420),
                      control1: point(rect, 0.338, 0.355),
                      control2: point(rect, 0.347, 0.390))
        path.addCurve(to: point(rect, 0.360, 0.500),
                      control1: point(rect, 0.355, 0.450),
                      control2: point(rect, 0.352, 0.478))
        path.addCurve(to: point(rect, 0.400, 0.560),
                      control1: point(rect, 0.365, 0.535),
                      control2: point(rect, 0.382, 0.553))
        path.addLine(to: point(rect, 0.460, 0.560))
        path.addCurve(to: point(rect, 0.500, 0.580),
                      control1: point(rect, 0.480, 0.560),
                      control2: point(rect, 0.490, 0.565))
        path.addCurve(to: point(rect, 0.540, 0.560),
                      control1: point(rect, 0.510, 0.565),
                      control2: point(rect, 0.520, 0.560))
        path.addLine(to: point(rect, 0.600, 0.560))
        path.addCurve(to: point(rect, 0.640, 0.500),
                      control1: point(rect, 0.618, 0.553),
                      control2: point(rect, 0.635, 0.535))
        path.addCurve(to: point(rect, 0.648, 0.420),
                      control1: point(rect, 0.648, 0.478),
                      control2: point(rect, 0.645, 0.450))
        path.addCurve(to: point(rect, 0.662, 0.300),
                      control1: point(rect, 0.653, 0.390),
                      control2: point(rect, 0.662, 0.355))
        path.addCurve(to: point(rect, 0.638, 0.222),
                      control1: point(rect, 0.662, 0.265),
                      control2: point(rect, 0.655, 0.232))
        path.closeSubpath()
        return path
    }

    static func arm(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(rect, 0.390, 0.225))
        path.addCurve(to: point(rect, 0.322, 0.285),
                      control1: point(rect, 0.365, 0.235),
                      control2: point(rect, 0.335, 0.255))
        path.addCurve(to: point(rect, 0.272, 0.480),
                      control1: point(rect, 0.305, 0.340),
                      control2: point(rect, 0.282, 0.415))
        path.addCurve(to: point(rect, 0.262, 0.565),
                      control1: point(rect, 0.268, 0.515),
                      control2: point(rect, 0.262, 0.540))
        path.addCurve(to: point(rect, 0.288, 0.600),
                      control1: point(rect, 0.262, 0.585),
                      control2: point(rect, 0.272, 0.598))
        path.addCurve(to: point(rect, 0.312, 0.565),
                      control1: point(rect, 0.302, 0.600),
                      control2: point(rect, 0.310, 0.585))
        path.addCurve(to: point(rect, 0.322, 0.470),
                      control1: point(rect, 0.316, 0.535),
                      control2: point(rect, 0.318, 0.500))
        path.addCurve(to: point(rect, 0.365, 0.295),
                      control1: point(rect, 0.330, 0.400),
                      control2: point(rect, 0.350, 0.330))
        path.closeSubpath()
        return path
    }

    static func leg(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(rect, 0.395, 0.540))
        path.addCurve(to: point(rect, 0.352, 0.720),
                      control1: point(rect, 0.370, 0.610),
                      control2: point(rect, 0.355, 0.665))
        path.addCurve(to: point(rect, 0.362, 0.900),
                      control1: point(rect, 0.349, 0.790),
                      control2: point(rect, 0.356, 0.855))
        path.addCurve(to: point(rect, 0.375, 0.945),
                      control1: point(rect, 0.365, 0.925),
                      control2: point(rect, 0.368, 0.938))
        path.addCurve(to: point(rect, 0.450, 0.950),
                      control1: point(rect, 0.392, 0.958),
                      control2: point(rect, 0.430, 0.958))
        path.addCurve(to: point(rect, 0.438, 0.900),
                      control1: point(rect, 0.443, 0.938),
                      control2: point(rect, 0.440, 0.920))
        path.addCurve(to: point(rect, 0.432, 0.720),
                      control1: point(rect, 0.435, 0.850),
                      control2: point(rect, 0.430, 0.780))
        path.addCurve(to: point(rect, 0.465, 0.560),
                      control1: point(rect, 0.436, 0.650),
                      control2: point(rect, 0.452, 0.595))
        path.closeSubpath()
        return path
    }

    static func torsoSegment(in rect: CGRect, top: CGFloat, bottom: CGFloat,
                             topInset: CGFloat = 0.360,
                             bottomInset: CGFloat = 0.365) -> Path {
        var path = Path()
        path.move(to: point(rect, topInset, top))
        path.addLine(to: point(rect, 1 - topInset, top))
        path.addCurve(to: point(rect, 1 - bottomInset, bottom),
                      control1: point(rect, 1 - topInset - 0.010, top + (bottom - top) * 0.55),
                      control2: point(rect, 1 - bottomInset + 0.004, bottom - (bottom - top) * 0.20))
        path.addLine(to: point(rect, bottomInset, bottom))
        path.addCurve(to: point(rect, topInset, top),
                      control1: point(rect, bottomInset - 0.004, bottom - (bottom - top) * 0.20),
                      control2: point(rect, topInset + 0.010, top + (bottom - top) * 0.55))
        path.closeSubpath()
        return path
    }
}

/// 完整人体剪影：头、颈、躯干、四肢用连续贝塞尔曲线绘制。
struct HumanBodyShape: Shape {
    var side: AnatomyBodySide = .front

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addPath(AnatomyGeometry.head(in: rect))
        path.addPath(AnatomyGeometry.neck(in: rect))
        path.addPath(AnatomyGeometry.torso(in: rect))
        let arm = AnatomyGeometry.arm(in: rect)
        path.addPath(arm)
        path.addPath(AnatomyGeometry.mirrored(arm, in: rect))
        let leg = AnatomyGeometry.leg(in: rect)
        path.addPath(leg)
        path.addPath(AnatomyGeometry.mirrored(leg, in: rect))
        return path
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

/// 一级部位命中区；与剪影共用同一套归一化坐标。
struct BodyRegionShape: Shape {
    let regionID: String
    var side: AnatomyBodySide = .front

    func path(in rect: CGRect) -> Path {
        switch regionID {
        case "head_neck":
            var path = AnatomyGeometry.head(in: rect)
            path.addPath(AnatomyGeometry.neck(in: rect))
            return path
        case "chest":
            guard side == .front else { return Path() }
            return AnatomyGeometry.torsoSegment(in: rect, top: 0.222, bottom: 0.412,
                                                topInset: 0.352, bottomInset: 0.360)
        case "abdomen":
            guard side == .front else { return Path() }
            return AnatomyGeometry.torsoSegment(in: rect, top: 0.412, bottom: 0.505,
                                                topInset: 0.360, bottomInset: 0.365)
        case "pelvis":
            guard side == .front else { return Path() }
            var path = AnatomyGeometry.torsoSegment(in: rect, top: 0.505, bottom: 0.575,
                                                    topInset: 0.365, bottomInset: 0.400)
            path.move(to: AnatomyGeometry.point(rect, 0.400, 0.575))
            path.addQuadCurve(to: AnatomyGeometry.point(rect, 0.600, 0.575),
                              control: AnatomyGeometry.point(rect, 0.500, 0.545))
            path.closeSubpath()
            return path
        case "back":
            guard side == .back else { return Path() }
            return AnatomyGeometry.torsoSegment(in: rect, top: 0.222, bottom: 0.575,
                                                topInset: 0.352, bottomInset: 0.400)
        case "upper_limb":
            let arm = AnatomyGeometry.arm(in: rect)
            var path = arm
            path.addPath(AnatomyGeometry.mirrored(arm, in: rect))
            return path
        case "lower_limb":
            let leg = AnatomyGeometry.leg(in: rect)
            var path = leg
            path.addPath(AnatomyGeometry.mirrored(leg, in: rect))
            return path
        default:
            return Path()
        }
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
