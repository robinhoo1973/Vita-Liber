import SwiftUI
import Domain

/// 既往史人体图索引（2026-10-22）。
///
/// 只帮助用户**找到已确诊的病名/做过的手术**，不做症状判断、不做疾病推断。
/// 一级部位点击 → 二级器官/组织；「背部/全身系统」作为图形外快捷入口。
struct BodyMapPicker: View {
    @Binding var regionID: String?
    @Binding var organID: String?

    private var selectedRegion: HealthHistoryCatalog.BodyRegion? {
        HealthHistoryCatalog.bodyRegions.first { $0.id == regionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.healthHistoryChooseRegion)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ZStack {
                silhouette
                regionButtons
            }
            .frame(width: 240, height: 320)
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                chip(L10n.healthHistorySystemic, id: "systemic", icon: "figure.arms.open")
                chip(regionName("back"), id: "back", icon: "figure.stand")
            }

            if let region = selectedRegion {
                Text(region.name)
                    .font(.subheadline.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(region.organs) { organ in
                            Button {
                                organID = organ.id
                            } label: {
                                Text(organ.name)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                            .tint(organID == organ.id
                                  ? Color("brand-primary", bundle: .main) : nil)
                            .accessibilityIdentifier("bodyMap.organ.\(organ.id)")
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bodyMap.picker")
    }

    private var silhouette: some View {
        ZStack {
            Circle().frame(width: 52, height: 52).offset(y: -126)
            Capsule().frame(width: 24, height: 34).offset(y: -94)
            RoundedRectangle(cornerRadius: 26).frame(width: 92, height: 128).offset(y: -20)
            Capsule().frame(width: 22, height: 118).offset(x: -66, y: -25)
            Capsule().frame(width: 22, height: 118).offset(x: 66, y: -25)
            Capsule().frame(width: 28, height: 128).offset(x: -24, y: 108)
            Capsule().frame(width: 28, height: 128).offset(x: 24, y: 108)
        }
        .foregroundStyle(Color("text-primary", bundle: .main).opacity(0.10))
        .accessibilityHidden(true)
    }

    private var regionButtons: some View {
        ZStack {
            regionShape(region: "head_neck", label: regionName("head_neck")) {
                Circle().frame(width: 58, height: 58).offset(y: -126)
            }
            regionShape(region: "chest", label: regionName("chest")) {
                RoundedRectangle(cornerRadius: 20).frame(width: 92, height: 64).offset(y: -46)
            }
            regionShape(region: "abdomen", label: regionName("abdomen")) {
                RoundedRectangle(cornerRadius: 18).frame(width: 88, height: 58).offset(y: 16)
            }
            regionShape(region: "pelvis", label: regionName("pelvis")) {
                RoundedRectangle(cornerRadius: 16).frame(width: 78, height: 38).offset(y: 62)
            }
            limbRegion(region: "upper_limb", label: regionName("upper_limb")) {
                HStack(spacing: 110) {
                    Capsule().frame(width: 30, height: 118)
                    Capsule().frame(width: 30, height: 118)
                }
                .offset(y: -25)
            }
            limbRegion(region: "lower_limb", label: regionName("lower_limb")) {
                HStack(spacing: 20) {
                    Capsule().frame(width: 36, height: 128)
                    Capsule().frame(width: 36, height: 128)
                }
                .offset(y: 108)
            }
        }
    }

    private func regionShape<Content: View>(region: String, label: String,
                                            @ViewBuilder shape: () -> Content) -> some View {
        Button {
            regionID = region
            organID = nil
        } label: {
            shape()
                .foregroundStyle(regionID == region
                                 ? Color("brand-primary", bundle: .main).opacity(0.30)
                                 : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(regionID == region ? .isSelected : [])
        .accessibilityIdentifier("bodyMap.region.\(region)")
    }

    /// 上下肢由左右两条 Capsule 组成，不能用单一 Shape 的 contentShape；
    /// 用矩形命中区包住整组，选中态以半透明底表达。
    private func limbRegion<Content: View>(region: String, label: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        Button {
            regionID = region
            organID = nil
        } label: {
            content()
                .background(regionID == region
                            ? Color("brand-primary", bundle: .main).opacity(0.16)
                            : Color.clear,
                            in: Rectangle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(regionID == region ? .isSelected : [])
        .accessibilityIdentifier("bodyMap.region.\(region)")
    }

    private func regionName(_ id: String) -> String {
        HealthHistoryCatalog.bodyRegions.first { $0.id == id }?.name ?? id
    }

    private func chip(_ title: String, id: String, icon: String) -> some View {
        Button {
            regionID = id
            organID = nil
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(regionID == id ? Color("brand-primary", bundle: .main) : nil)
        .accessibilityIdentifier("bodyMap.region.\(id)")
    }
}
