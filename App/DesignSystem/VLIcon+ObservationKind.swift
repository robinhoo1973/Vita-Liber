import SwiftUI
import Domain

/// 观察类型的图标映射（Domain `ObservationKind` → VLIcon；Domain 不持 Image）。
/// 图标单出口纪律：与 VLIcon 同目录的非生成文件（VLIcon.swift 为自动生成、勿手改）。
extension ObservationKind {
    var icon: Image {
        switch self {
        case .stool: return VLIcon.symStool
        case .urine: return VLIcon.symUrine
        case .skin: return VLIcon.symSkin
        case .eye: return VLIcon.symEye
        case .secretion: return VLIcon.symSecretion
        case .swelling: return VLIcon.symSwelling
        case .generic: return VLIcon.symGeneric
        case .custom: return VLIcon.symCustom
        }
    }
}
