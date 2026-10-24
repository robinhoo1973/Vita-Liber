import SwiftUI
import Domain

/// 二级器官层：位置、形状、着色与可访问控件。
/// 形状是解剖示意，不是医学影像；仅用于选择用户已确诊/已手术的器官。

struct OrganPlacement: Equatable {
    let id: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

enum OrganLayout {
    static func placements(regionID: String, gender: String?) -> [OrganPlacement] {
        let all: [OrganPlacement]
        switch regionID {
        case "head_neck":
            // 两列交错，避免 44pt 命中矩形在同一中轴上互相覆盖。
            // 2026-10-24：补脑位；头/脑上移，给眼耳鼻咽喉留出更大画布。
            all = [
                .init(id: "brain", x: 0.50, y: 0.15, width: 0.20, height: 0.14),
                .init(id: "head", x: 0.50, y: 0.30, width: 0.17, height: 0.12),
                .init(id: "eye", x: 0.33, y: 0.34, width: 0.14, height: 0.10),
                .init(id: "ear", x: 0.67, y: 0.34, width: 0.14, height: 0.10),
                .init(id: "nose_throat", x: 0.50, y: 0.47, width: 0.15, height: 0.12),
                .init(id: "mouth", x: 0.32, y: 0.63, width: 0.14, height: 0.10),
                .init(id: "thyroid", x: 0.68, y: 0.63, width: 0.15, height: 0.10),
                .init(id: "neck", x: 0.50, y: 0.80, width: 0.15, height: 0.12),
            ]
        case "chest":
            all = [
                .init(id: "lung", x: 0.50, y: 0.40, width: 0.60, height: 0.32),
                .init(id: "breast", x: 0.50, y: 0.45, width: 0.40, height: 0.22),
                .init(id: "heart", x: 0.34, y: 0.58, width: 0.20, height: 0.22),
                .init(id: "esophagus", x: 0.50, y: 0.26, width: 0.06, height: 0.26),
            ]
        case "abdomen":
            all = [
                .init(id: "liver", x: 0.36, y: 0.31, width: 0.34, height: 0.20),
                .init(id: "stomach", x: 0.64, y: 0.33, width: 0.22, height: 0.16),
                .init(id: "gallbladder", x: 0.28, y: 0.50, width: 0.08, height: 0.09),
                .init(id: "pancreas", x: 0.56, y: 0.43, width: 0.30, height: 0.09),
                .init(id: "spleen", x: 0.84, y: 0.34, width: 0.12, height: 0.14),
                .init(id: "kidney", x: 0.50, y: 0.60, width: 0.50, height: 0.15),
                .init(id: "intestine", x: 0.50, y: 0.80, width: 0.38, height: 0.20),
            ]
        case "pelvis":
            all = [
                .init(id: "uterus", x: 0.50, y: 0.35, width: 0.20, height: 0.16),
                .init(id: "ovary", x: 0.50, y: 0.57, width: 0.36, height: 0.09),
                .init(id: "prostate", x: 0.50, y: 0.57, width: 0.14, height: 0.09),
                .init(id: "bladder", x: 0.50, y: 0.80, width: 0.16, height: 0.13),
            ]
        case "back":
            all = [
                .init(id: "spinal_cord", x: 0.50, y: 0.36, width: 0.07, height: 0.30),
                .init(id: "spine", x: 0.50, y: 0.56, width: 0.14, height: 0.46),
            ]
        case "upper_limb":
            all = [
                // 剪影放大窗口取左臂；命中点沿上臂自然下垂方向排列。
                .init(id: "shoulder", x: 0.70, y: 0.14, width: 0.30, height: 0.16),
                .init(id: "arm", x: 0.64, y: 0.38, width: 0.24, height: 0.28),
                .init(id: "elbow", x: 0.56, y: 0.62, width: 0.20, height: 0.12),
                .init(id: "wrist_hand", x: 0.42, y: 0.86, width: 0.28, height: 0.18),
            ]
        case "lower_limb":
            all = [
                .init(id: "hip", x: 0.50, y: 0.14, width: 0.34, height: 0.16),
                .init(id: "thigh", x: 0.50, y: 0.38, width: 0.26, height: 0.28),
                .init(id: "knee", x: 0.50, y: 0.62, width: 0.20, height: 0.12),
                .init(id: "ankle_foot", x: 0.50, y: 0.86, width: 0.26, height: 0.18),
            ]
        case "systemic":
            all = [
                .init(id: "endocrine", x: 0.27, y: 0.25, width: 0.30, height: 0.20),
                .init(id: "blood", x: 0.73, y: 0.25, width: 0.30, height: 0.20),
                .init(id: "immune", x: 0.27, y: 0.55, width: 0.30, height: 0.20),
                .init(id: "mental", x: 0.73, y: 0.55, width: 0.30, height: 0.20),
                .init(id: "skeletal", x: 0.27, y: 0.83, width: 0.30, height: 0.18),
                .init(id: "genetic", x: 0.73, y: 0.83, width: 0.30, height: 0.18),
            ]
        default:
            all = []
        }
        // 已知性别时隐藏不属于该性别的盆腔器官；未知/其他保留全部，避免误删。
        guard regionID == "pelvis", let gender else { return all }
        if gender == "male" {
            return all.filter { $0.id != "uterus" && $0.id != "ovary" }
        }
        if gender == "female" {
            return all.filter { $0.id != "prostate" }
        }
        return all
    }

    static func placement(regionID: String, organID: String) -> OrganPlacement? {
        placements(regionID: regionID, gender: nil).first { $0.id == organID }
    }
}

// MARK: - 器官形状

struct OrganGlyphShape: Shape {
    let organID: String

    static let glyphIDs: Set<String> = [
        "heart", "lung", "liver", "stomach", "gallbladder", "pancreas",
        "kidney", "spleen", "brain", "thyroid", "bladder", "uterus",
        "ovary", "prostate", "spine",
    ]

    static func hasGlyph(_ id: String) -> Bool { glyphIDs.contains(id) }

    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        switch organID {
        case "heart":
            path.move(to: p(0.50, 0.92))
            path.addCurve(to: p(0.06, 0.30),
                          control1: p(0.35, 0.74), control2: p(0.06, 0.56))
            path.addCurve(to: p(0.30, 0.05),
                          control1: p(0.06, 0.12), control2: p(0.22, 0.03))
            path.addCurve(to: p(0.50, 0.22),
                          control1: p(0.38, 0.07), control2: p(0.44, 0.18))
            path.addCurve(to: p(0.70, 0.05),
                          control1: p(0.56, 0.18), control2: p(0.62, 0.07))
            path.addCurve(to: p(0.94, 0.30),
                          control1: p(0.78, 0.03), control2: p(0.94, 0.12))
            path.addCurve(to: p(0.50, 0.92),
                          control1: p(0.94, 0.56), control2: p(0.65, 0.74))
            path.closeSubpath()
        case "lung":
            path.addRoundedRect(in: CGRect(x: rect.minX + 0.465 * rect.width,
                                           y: rect.minY + 0.02 * rect.height,
                                           width: 0.070 * rect.width,
                                           height: 0.340 * rect.height),
                                cornerSize: CGSize(width: 3, height: 3))
            path.move(to: p(0.44, 0.18))
            path.addCurve(to: p(0.08, 0.46),
                          control1: p(0.22, 0.18), control2: p(0.05, 0.28))
            path.addCurve(to: p(0.22, 0.88),
                          control1: p(0.05, 0.66), control2: p(0.10, 0.84))
            path.addCurve(to: p(0.46, 0.90),
                          control1: p(0.30, 0.92), control2: p(0.40, 0.92))
            path.addCurve(to: p(0.46, 0.40),
                          control1: p(0.48, 0.66), control2: p(0.44, 0.52))
            path.closeSubpath()
            path.move(to: p(0.56, 0.18))
            path.addCurve(to: p(0.92, 0.46),
                          control1: p(0.78, 0.18), control2: p(0.95, 0.28))
            path.addCurve(to: p(0.78, 0.88),
                          control1: p(0.95, 0.66), control2: p(0.90, 0.84))
            path.addCurve(to: p(0.54, 0.90),
                          control1: p(0.70, 0.92), control2: p(0.60, 0.92))
            path.addCurve(to: p(0.54, 0.40),
                          control1: p(0.52, 0.66), control2: p(0.56, 0.52))
            path.closeSubpath()
        case "liver":
            path.move(to: p(0.06, 0.30))
            path.addCurve(to: p(0.50, 0.10),
                          control1: p(0.22, 0.10), control2: p(0.36, 0.06))
            path.addCurve(to: p(0.94, 0.34),
                          control1: p(0.70, 0.14), control2: p(0.88, 0.20))
            path.addCurve(to: p(0.86, 0.72),
                          control1: p(0.96, 0.50), control2: p(0.94, 0.62))
            path.addCurve(to: p(0.48, 0.82),
                          control1: p(0.72, 0.82), control2: p(0.58, 0.84))
            path.addCurve(to: p(0.36, 0.64),
                          control1: p(0.42, 0.80), control2: p(0.38, 0.72))
            path.addCurve(to: p(0.06, 0.30),
                          control1: p(0.22, 0.54), control2: p(0.10, 0.42))
            path.closeSubpath()
        case "stomach":
            path.move(to: p(0.30, 0.18))
            path.addCurve(to: p(0.62, 0.10),
                          control1: p(0.40, 0.08), control2: p(0.54, 0.04))
            path.addCurve(to: p(0.88, 0.40),
                          control1: p(0.78, 0.16), control2: p(0.90, 0.28))
            path.addCurve(to: p(0.78, 0.72),
                          control1: p(0.90, 0.54), control2: p(0.86, 0.64))
            path.addCurve(to: p(0.44, 0.90),
                          control1: p(0.68, 0.84), control2: p(0.56, 0.90))
            path.addCurve(to: p(0.24, 0.74),
                          control1: p(0.34, 0.90), control2: p(0.26, 0.84))
            path.addCurve(to: p(0.22, 0.42),
                          control1: p(0.18, 0.60), control2: p(0.18, 0.50))
            path.addCurve(to: p(0.30, 0.18),
                          control1: p(0.24, 0.30), control2: p(0.26, 0.22))
            path.closeSubpath()
        case "gallbladder":
            path.move(to: p(0.38, 0.08))
            path.addCurve(to: p(0.66, 0.22),
                          control1: p(0.54, 0.06), control2: p(0.66, 0.10))
            path.addCurve(to: p(0.62, 0.62),
                          control1: p(0.68, 0.36), control2: p(0.68, 0.50))
            path.addCurve(to: p(0.42, 0.92),
                          control1: p(0.58, 0.76), control2: p(0.52, 0.88))
            path.addCurve(to: p(0.30, 0.58),
                          control1: p(0.32, 0.92), control2: p(0.26, 0.76))
            path.addCurve(to: p(0.38, 0.08),
                          control1: p(0.34, 0.42), control2: p(0.28, 0.22))
            path.closeSubpath()
        case "pancreas":
            path.move(to: p(0.08, 0.50))
            path.addCurve(to: p(0.40, 0.28),
                          control1: p(0.16, 0.36), control2: p(0.28, 0.28))
            path.addCurve(to: p(0.82, 0.34),
                          control1: p(0.52, 0.26), control2: p(0.68, 0.28))
            path.addCurve(to: p(0.94, 0.52),
                          control1: p(0.92, 0.38), control2: p(0.96, 0.44))
            path.addCurve(to: p(0.62, 0.72),
                          control1: p(0.86, 0.66), control2: p(0.74, 0.72))
            path.addCurve(to: p(0.34, 0.64),
                          control1: p(0.50, 0.72), control2: p(0.42, 0.68))
            path.addCurve(to: p(0.08, 0.50),
                          control1: p(0.22, 0.60), control2: p(0.12, 0.58))
            path.closeSubpath()
        case "kidney":
            path.move(to: p(0.30, 0.12))
            path.addCurve(to: p(0.08, 0.38),
                          control1: p(0.16, 0.14), control2: p(0.06, 0.24))
            path.addCurve(to: p(0.26, 0.88),
                          control1: p(0.10, 0.62), control2: p(0.16, 0.82))
            path.addCurve(to: p(0.38, 0.76),
                          control1: p(0.34, 0.92), control2: p(0.40, 0.84))
            path.addCurve(to: p(0.34, 0.52),
                          control1: p(0.36, 0.68), control2: p(0.30, 0.58))
            path.addCurve(to: p(0.38, 0.28),
                          control1: p(0.38, 0.44), control2: p(0.40, 0.36))
            path.addCurve(to: p(0.30, 0.12),
                          control1: p(0.36, 0.18), control2: p(0.34, 0.12))
            path.closeSubpath()
            path.move(to: p(0.70, 0.12))
            path.addCurve(to: p(0.92, 0.38),
                          control1: p(0.84, 0.14), control2: p(0.94, 0.24))
            path.addCurve(to: p(0.74, 0.88),
                          control1: p(0.90, 0.62), control2: p(0.84, 0.82))
            path.addCurve(to: p(0.62, 0.76),
                          control1: p(0.66, 0.92), control2: p(0.60, 0.84))
            path.addCurve(to: p(0.66, 0.52),
                          control1: p(0.64, 0.68), control2: p(0.70, 0.58))
            path.addCurve(to: p(0.62, 0.28),
                          control1: p(0.62, 0.44), control2: p(0.60, 0.36))
            path.addCurve(to: p(0.70, 0.12),
                          control1: p(0.64, 0.18), control2: p(0.66, 0.12))
            path.closeSubpath()
        case "spleen":
            path.move(to: p(0.58, 0.08))
            path.addCurve(to: p(0.90, 0.44),
                          control1: p(0.78, 0.10), control2: p(0.92, 0.24))
            path.addCurve(to: p(0.62, 0.90),
                          control1: p(0.88, 0.70), control2: p(0.78, 0.86))
            path.addCurve(to: p(0.34, 0.78),
                          control1: p(0.48, 0.94), control2: p(0.40, 0.88))
            path.addCurve(to: p(0.28, 0.36),
                          control1: p(0.26, 0.64), control2: p(0.24, 0.48))
            path.addCurve(to: p(0.58, 0.08),
                          control1: p(0.34, 0.20), control2: p(0.44, 0.10))
            path.closeSubpath()
        case "brain":
            path.move(to: p(0.50, 0.08))
            path.addCurve(to: p(0.86, 0.22),
                          control1: p(0.68, 0.04), control2: p(0.82, 0.08))
            path.addCurve(to: p(0.90, 0.58),
                          control1: p(0.94, 0.34), control2: p(0.94, 0.48))
            path.addCurve(to: p(0.72, 0.88),
                          control1: p(0.88, 0.72), control2: p(0.82, 0.84))
            path.addCurve(to: p(0.50, 0.82),
                          control1: p(0.64, 0.92), control2: p(0.56, 0.88))
            path.addCurve(to: p(0.28, 0.88),
                          control1: p(0.44, 0.88), control2: p(0.36, 0.92))
            path.addCurve(to: p(0.10, 0.58),
                          control1: p(0.18, 0.84), control2: p(0.12, 0.72))
            path.addCurve(to: p(0.14, 0.22),
                          control1: p(0.06, 0.48), control2: p(0.06, 0.34))
            path.addCurve(to: p(0.50, 0.08),
                          control1: p(0.18, 0.08), control2: p(0.32, 0.04))
            path.closeSubpath()
        case "thyroid":
            path.move(to: p(0.08, 0.26))
            path.addCurve(to: p(0.42, 0.34),
                          control1: p(0.22, 0.12), control2: p(0.34, 0.16))
            path.addCurve(to: p(0.48, 0.54),
                          control1: p(0.46, 0.40), control2: p(0.48, 0.46))
            path.addLine(to: p(0.52, 0.54))
            path.addCurve(to: p(0.58, 0.34),
                          control1: p(0.52, 0.46), control2: p(0.54, 0.40))
            path.addCurve(to: p(0.92, 0.26),
                          control1: p(0.66, 0.16), control2: p(0.78, 0.12))
            path.addCurve(to: p(0.76, 0.72),
                          control1: p(0.96, 0.46), control2: p(0.88, 0.64))
            path.addCurve(to: p(0.54, 0.82),
                          control1: p(0.68, 0.82), control2: p(0.60, 0.84))
            path.addCurve(to: p(0.46, 0.82),
                          control1: p(0.50, 0.84), control2: p(0.48, 0.84))
            path.addCurve(to: p(0.24, 0.72),
                          control1: p(0.40, 0.84), control2: p(0.32, 0.82))
            path.addCurve(to: p(0.08, 0.26),
                          control1: p(0.12, 0.64), control2: p(0.04, 0.46))
            path.closeSubpath()
        case "bladder":
            path.move(to: p(0.50, 0.10))
            path.addCurve(to: p(0.82, 0.38),
                          control1: p(0.68, 0.08), control2: p(0.82, 0.20))
            path.addCurve(to: p(0.56, 0.76),
                          control1: p(0.82, 0.58), control2: p(0.70, 0.70))
            path.addLine(to: p(0.56, 0.92))
            path.addLine(to: p(0.44, 0.92))
            path.addLine(to: p(0.44, 0.76))
            path.addCurve(to: p(0.18, 0.38),
                          control1: p(0.30, 0.70), control2: p(0.18, 0.58))
            path.addCurve(to: p(0.50, 0.10),
                          control1: p(0.18, 0.20), control2: p(0.32, 0.08))
            path.closeSubpath()
        case "uterus":
            path.move(to: p(0.34, 0.10))
            path.addCurve(to: p(0.66, 0.10),
                          control1: p(0.44, 0.04), control2: p(0.56, 0.04))
            path.addCurve(to: p(0.62, 0.38),
                          control1: p(0.68, 0.22), control2: p(0.66, 0.30))
            path.addCurve(to: p(0.56, 0.72),
                          control1: p(0.58, 0.50), control2: p(0.58, 0.60))
            path.addLine(to: p(0.62, 0.88))
            path.addLine(to: p(0.50, 0.82))
            path.addLine(to: p(0.38, 0.88))
            path.addLine(to: p(0.44, 0.72))
            path.addCurve(to: p(0.38, 0.38),
                          control1: p(0.42, 0.60), control2: p(0.42, 0.50))
            path.addCurve(to: p(0.34, 0.10),
                          control1: p(0.34, 0.30), control2: p(0.32, 0.22))
            path.closeSubpath()
            path.move(to: p(0.34, 0.16))
            path.addCurve(to: p(0.08, 0.30),
                          control1: p(0.24, 0.14), control2: p(0.12, 0.18))
            path.addCurve(to: p(0.10, 0.40),
                          control1: p(0.02, 0.34), control2: p(0.04, 0.38))
            path.addCurve(to: p(0.34, 0.26),
                          control1: p(0.18, 0.36), control2: p(0.26, 0.32))
            path.closeSubpath()
            path.move(to: p(0.66, 0.16))
            path.addCurve(to: p(0.92, 0.30),
                          control1: p(0.76, 0.14), control2: p(0.88, 0.18))
            path.addCurve(to: p(0.90, 0.40),
                          control1: p(0.98, 0.34), control2: p(0.96, 0.38))
            path.addCurve(to: p(0.66, 0.26),
                          control1: p(0.82, 0.36), control2: p(0.74, 0.32))
            path.closeSubpath()
        case "ovary":
            path.addEllipse(in: CGRect(x: rect.minX + 0.10 * rect.width,
                                       y: rect.minY + 0.32 * rect.height,
                                       width: 0.24 * rect.width,
                                       height: 0.30 * rect.height))
            path.addEllipse(in: CGRect(x: rect.minX + 0.66 * rect.width,
                                       y: rect.minY + 0.32 * rect.height,
                                       width: 0.24 * rect.width,
                                       height: 0.30 * rect.height))
        case "prostate":
            path.move(to: p(0.50, 0.14))
            path.addCurve(to: p(0.86, 0.42),
                          control1: p(0.70, 0.12), control2: p(0.86, 0.24))
            path.addCurve(to: p(0.72, 0.84),
                          control1: p(0.86, 0.64), control2: p(0.80, 0.78))
            path.addCurve(to: p(0.28, 0.84),
                          control1: p(0.58, 0.94), control2: p(0.42, 0.94))
            path.addCurve(to: p(0.14, 0.42),
                          control1: p(0.18, 0.78), control2: p(0.14, 0.62))
            path.addCurve(to: p(0.50, 0.14),
                          control1: p(0.14, 0.24), control2: p(0.30, 0.12))
            path.closeSubpath()
        case "spine":
            for index in 0..<9 {
                let y = 0.03 + CGFloat(index) * 0.105
                let inset = 0.20 + CGFloat(abs(index - 4)) * 0.018
                path.addRoundedRect(in: CGRect(x: rect.minX + inset * rect.width,
                                               y: rect.minY + y * rect.height,
                                               width: (1 - 2 * inset) * rect.width,
                                               height: 0.072 * rect.height),
                                    cornerSize: CGSize(width: 4, height: 4))
            }
        default:
            break
        }
        return path
    }
}

/// 肠道用曲线描边，比实心块更像肠管。
struct IntestineLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.16, 0.22))
        path.addCurve(to: p(0.52, 0.26),
                      control1: p(0.30, 0.10), control2: p(0.42, 0.36))
        path.addCurve(to: p(0.84, 0.38),
                      control1: p(0.66, 0.18), control2: p(0.72, 0.46))
        path.addCurve(to: p(0.40, 0.52),
                      control1: p(0.94, 0.30), control2: p(0.62, 0.54))
        path.addCurve(to: p(0.18, 0.64),
                      control1: p(0.26, 0.50), control2: p(0.34, 0.68))
        path.addCurve(to: p(0.62, 0.70),
                      control1: p(0.06, 0.60), control2: p(0.44, 0.72))
        path.addCurve(to: p(0.82, 0.82),
                      control1: p(0.78, 0.68), control2: p(0.66, 0.84))
        path.addCurve(to: p(0.50, 0.90),
                      control1: p(0.94, 0.80), control2: p(0.72, 0.94))
        return path
    }
}

// MARK: - 着色与图标

enum OrganStyle {
    static func tint(_ id: String) -> Color {
        switch id {
        case "heart", "blood": return Color("semantic-danger", bundle: .main)
        case "lung", "kidney", "bladder", "prostate": return Color("brand-primary", bundle: .main)
        case "liver", "gallbladder", "stomach", "pancreas": return Color("semantic-warning", bundle: .main)
        case "spleen", "brain", "mental": return Color("grade-e", bundle: .main)
        case "intestine": return Color("card-kind-lab", bundle: .main)
        case "thyroid", "endocrine", "immune": return Color("semantic-success", bundle: .main)
        case "uterus": return Color("member-mother", bundle: .main)
        case "ovary": return Color("member-daughter", bundle: .main)
        case "spine", "spinal_cord", "skeletal", "genetic": return Color("text-secondary", bundle: .main)
        default: return Color("brand-primary", bundle: .main)
        }
    }

    /// 专业解剖插图（Servier Medical Art，CC BY 4.0；来源 SMART 素材库
    /// https://smart.servier.com）——优先于手绘 Shape。新增甲状腺/子宫/
    /// 卵巢/乳腺四枚，消除这些常见病种退化成「首字圆形」的问题。
    /// 目录里「精神/心理」的器官 id 是 `mental`，素材名仍按解剖命名 `anatomy-brain`。
    static func anatomyAsset(_ id: String) -> String? {
        switch id {
        case "heart", "liver", "lung", "kidney", "spleen", "stomach",
             "pancreas", "intestine", "bladder", "thyroid",
             "uterus", "ovary", "breast",
             "head", "brain", "eye", "ear", "mouth", "neck",
             "shoulder", "arm", "elbow", "hip", "thigh", "knee",
             "spine", "skeletal", "blood", "immune", "genetic":
            return "anatomy-\(id)"
        case "nose_throat":
            return "anatomy-nose-throat"
        case "wrist_hand":
            return "anatomy-wrist-hand"
        case "ankle_foot":
            return "anatomy-ankle-foot"
        case "spinal_cord":
            return "anatomy-spine"
        case "mental":
            return "anatomy-brain"
        case "endocrine":
            return "anatomy-thyroid"
        default:
            return nil
        }
    }

    static func assetName(_ id: String) -> String? {
        switch id {
        case "head": return "skull"
        case "eye": return "eye"
        case "ear": return "ear"
        case "nose_throat": return "nose"
        case "mouth": return "mouth"
        case "thyroid": return "thyroid"
        case "neck": return "throat"
        case "esophagus": return "throat"
        case "heart": return "heart"
        case "lung": return "lungs"
        case "stomach": return "stomach"
        case "liver": return "liver"
        case "pancreas": return "pancreas"
        case "intestine": return "intestine"
        case "kidney": return "kidney"
        case "spleen": return "spleen"
        case "bladder": return "bladder"
        case "prostate": return "prostate"
        case "spine", "spinal_cord": return "spine"
        case "shoulder", "elbow", "hip", "knee": return "joints"
        case "arm", "thigh", "skeletal": return "bone"
        case "wrist_hand": return "hand"
        case "ankle_foot": return "foot"
        case "endocrine": return "thyroid"
        case "blood", "genetic": return "blood-cells"
        case "immune": return "donation"
        case "mental": return "brain"
        default: return nil
        }
    }
}

// MARK: - 器官层视图

struct RegionAnatomyView: View {
    let region: HealthHistoryCatalog.BodyRegion
    @Binding var organID: String?
    let gender: String?
    let onSelect: (HealthHistoryCatalog.BodyOrgan) -> Void

    private var placements: [OrganPlacement] {
        OrganLayout.placements(regionID: region.id, gender: gender)
    }

    private var organs: [HealthHistoryCatalog.BodyOrgan] {
        let ids = Set(placements.map(\.id))
        return region.organs.filter { ids.contains($0.id) }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let displayed = displayedPlacements(in: size)
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [
                        Color("surface-tint-start", bundle: .main).opacity(0.58),
                        Color("bg-grouped", bundle: .main).opacity(0.92),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                if region.id != "systemic" {
                    BodySilhouetteBackdrop(regionID: region.id)
                }
                ForEach(displayed, id: \.id) { placement in
                    if let organ = organs.first(where: { $0.id == placement.id }) {
                        OrganHotspot(organ: organ, placement: placement,
                                     selected: organID == organ.id, size: size) {
                            onSelect(organ)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .frame(height: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bodyMap.regionLayer.\(region.id)")
    }

    /// 器官热点与剪影使用同一裁切换算：器官位置随真实人体缩放，
    /// 不再以卡片宽高直接铺坐标（旧版会与放大后的身体错位）。
    private func displayedPlacements(in size: CGSize) -> [OrganPlacement] {
        guard let crop = BodySilhouette.crop(for: region.id),
              size.width > 0, size.height > 0 else { return placements }
        let layout = BodySilhouette.layout(crop: crop, in: size)
        let rect = BodySilhouette.displayedCrop(crop, layout: layout)
        return placements.map { placement in
            OrganPlacement(
                id: placement.id,
                x: (rect.minX + placement.x * rect.width) / size.width,
                y: (rect.minY + placement.y * rect.height) / size.height,
                width: placement.width * rect.width / size.width,
                height: placement.height * rect.height / size.height)
        }
    }
}

private struct OrganHotspot: View {
    let organ: HealthHistoryCatalog.BodyOrgan
    let placement: OrganPlacement
    let selected: Bool
    let size: CGSize
    let action: () -> Void

    /// 头颈/四肢的最小可见尺寸：旧版 20pt 让眼/耳退化成小圆点。
    private var minArtSize: CGFloat {
        switch organ.id {
        case "brain", "head": return 56
        case "eye", "ear", "mouth", "thyroid", "nose_throat", "neck": return 44
        default: return 48
        }
    }

    private var hitWidth: CGFloat { max(44, placement.width * size.width) }
    private var hitHeight: CGFloat { max(44, placement.height * size.height) }
    /// 只有仍用矢量 Shape 绘制器官才按字形命中；有解剖插图的器官（心/肝/肺/
    /// 肾/脾/胃/胰/肠）可见图形与 `OrganGlyphShape` 不再重合（如肾的双瓣
    /// 中间空隙正好落在缩小后的位图中心），按矩形命中才不至于点图无效。
    private var usesPathHit: Bool {
        OrganStyle.anatomyAsset(organ.id) == nil && OrganGlyphShape.hasGlyph(organ.id)
    }
    private var hitShape: AnyShape {
        usesPathHit ? AnyShape(OrganGlyphShape(organID: organ.id)) : AnyShape(Rectangle())
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if selected {
                    Circle()
                        .fill(OrganStyle.tint(organ.id).opacity(0.16))
                        .frame(width: hitWidth + 14, height: hitWidth + 14)
                }
                OrganGlyph(organ: organ, selected: selected)
                    .frame(width: max(minArtSize, placement.width * size.width * 0.96),
                           height: max(minArtSize, placement.height * size.height * 0.96))
            }
            .frame(width: hitWidth, height: hitHeight)
            .contentShape(hitShape)
        }
        .buttonStyle(.plain)
        .position(x: placement.x * size.width, y: placement.y * size.height)
        .accessibilityLabel(organ.name)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isButton.union(.isSelected) : .isButton)
        .accessibilityIdentifier("bodyMap.organHotspot.\(organ.id)")
    }
}

struct OrganGlyph: View {
    let organ: HealthHistoryCatalog.BodyOrgan
    let selected: Bool

    private var tint: Color { OrganStyle.tint(organ.id) }

    var body: some View {
        Group {
            if let anatomy = OrganStyle.anatomyAsset(organ.id) {
                Image(anatomy)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
            } else if OrganGlyphShape.hasGlyph(organ.id) {
                if organ.id == "intestine" {
                    IntestineLineShape()
                        .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                } else {
                    OrganGlyphShape(organID: organ.id)
                        .fill(LinearGradient(colors: [tint.opacity(0.98), tint.opacity(0.62)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(
                            OrganGlyphShape(organID: organ.id)
                                .stroke(Color.white.opacity(0.78), lineWidth: 0.8)
                        )
                }
            } else if let asset = OrganStyle.assetName(organ.id) {
                Image("ic-organ-\(asset)")
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    Text(String(organ.name.prefix(1)))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                }
            }
        }
        .scaleEffect(selected ? 1.06 : 1.0)
        .shadow(color: selected ? tint.opacity(0.30) : .clear, radius: 6, y: 2)
    }
}

struct OrganChip: View {
    let organ: HealthHistoryCatalog.BodyOrgan
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                OrganMiniIcon(organ: organ)
                Text(organ.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected
                             ? OrganStyle.tint(organ.id)
                             : Color("text-primary", bundle: .main))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(selected
                        ? OrganStyle.tint(organ.id).opacity(0.16)
                        : Color("bg-grouped", bundle: .main),
                        in: Capsule())
            .overlay(
                Capsule().stroke(selected
                                 ? OrganStyle.tint(organ.id).opacity(0.70)
                                 : Color("text-primary", bundle: .main).opacity(0.06),
                                 lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isButton.union(.isSelected) : .isButton)
        .accessibilityIdentifier("bodyMap.organ.\(organ.id)")
    }
}

private struct OrganMiniIcon: View {
    let organ: HealthHistoryCatalog.BodyOrgan

    var body: some View {
        let tint = OrganStyle.tint(organ.id)
        Group {
            if let anatomy = OrganStyle.anatomyAsset(organ.id) {
                Image(anatomy)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            } else if OrganGlyphShape.hasGlyph(organ.id) {
                if organ.id == "intestine" {
                    IntestineLineShape()
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 28, height: 28)
                } else {
                    OrganGlyphShape(organID: organ.id)
                        .fill(tint)
                        .frame(width: 28, height: 28)
                }
            } else if let asset = OrganStyle.assetName(organ.id) {
                Image("ic-organ-\(asset)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Circle().fill(tint.opacity(0.18)).frame(width: 28, height: 28)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 选中器官的大图详情：二级人体图上的热区较小，选中后在图下给出
/// 104pt 解剖插图 + 名称，保证眼/耳/脑等小器官也能看清。
struct OrganDetailCard: View {
    let organ: HealthHistoryCatalog.BodyOrgan

    var body: some View {
        HStack(spacing: 14) {
            OrganGlyph(organ: organ, selected: true)
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            Text(organ.name)
                .font(.headline)
                .foregroundStyle(Color("text-primary", bundle: .main))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(Color("bg-grouped", bundle: .main),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(OrganStyle.tint(organ.id).opacity(0.26), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
