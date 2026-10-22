import SwiftUI
import Domain

/// 既往史人体图索引（2026-10-22 第二版）。
///
/// 两级交互：全身剪影点部位 → 该部位放大 + 器官/组织热点。
/// 只帮助用户找到**已确诊的病名/做过的手术**，不做症状判断、不做疾病推断。
/// 全部为 SwiftUI 矢量 Shape，无第三方依赖、无网络、无位图缩放失真。
struct BodyMapPicker: View {
    @Binding var regionID: String?
    @Binding var organID: String?
    /// male/female/other；已知性别时盆腔只显示对应器官。
    var gender: String? = nil

    @State private var side: AnatomyBodySide = .front
    @State private var zoomedRegionID: String?
    @AccessibilityFocusState private var zoomedFocus: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedRegion: HealthHistoryCatalog.BodyRegion? {
        HealthHistoryCatalog.bodyRegions.first { $0.id == regionID }
    }

    private var zoomedRegion: HealthHistoryCatalog.BodyRegion? {
        guard let zoomedRegionID else { return nil }
        return HealthHistoryCatalog.bodyRegions.first { $0.id == zoomedRegionID }
    }

    private var selectedName: String? {
        if let region = selectedRegion, let organID,
           let organ = region.organs.first(where: { $0.id == organID }) {
            return organ.name
        }
        return selectedRegion?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let region = zoomedRegion {
                zoomHeader(region)
                Text(L10n.healthHistoryOrganHint)
                    .font(.caption)
                    .foregroundStyle(Color("text-secondary", bundle: .main))
                RegionAnatomyView(region: region, organID: $organID, gender: gender) { organ in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        organID = organ.id
                    }
                }
                .transition(.scale(scale: 0.86, anchor: .center).combined(with: .opacity))
                organChips(region)
            } else {
                HStack {
                    Text(L10n.healthHistoryTapRegion)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color("text-secondary", bundle: .main))
                    Spacer()
                    sideToggle
                }
                FullBodyAnatomyView(side: side, selectedRegionID: regionID) { id in
                    selectRegion(id)
                }
                .transition(.scale(scale: 1.05, anchor: .center).combined(with: .opacity))
                regionChips
            }

            if let selectedName {
                Label(String(format: L10n.healthHistorySelectedFmt, selectedName),
                      systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color("semantic-success", bundle: .main))
                    .accessibilityIdentifier("bodyMap.selected")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: zoomedRegionID)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bodyMap.picker")
    }

    private func zoomHeader(_ region: HealthHistoryCatalog.BodyRegion) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                    zoomedRegionID = nil
                    zoomedFocus = nil
                }
            } label: {
                Label(L10n.healthHistoryWholeBody, systemImage: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color("brand-primary", bundle: .main))
            .accessibilitySortPriority(3)
            .accessibilityIdentifier("bodyMap.back")

            Spacer()

            Text(region.name)
                .font(.headline)
                .foregroundStyle(Color("text-primary", bundle: .main))
                .accessibilitySortPriority(2)
                .accessibilityFocused($zoomedFocus, equals: Optional(region.id))
            Spacer()
        }
    }

    private var sideToggle: some View {
        HStack(spacing: 0) {
            ForEach(AnatomyBodySide.allCases) { item in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        side = item
                        if item == .back, ["chest", "abdomen", "pelvis"].contains(regionID) {
                            regionID = "back"
                            organID = nil
                        }
                    }
                } label: {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(side == item
                                    ? Color("brand-primary", bundle: .main).opacity(0.14)
                                    : Color.clear,
                                    in: Capsule())
                        .foregroundStyle(side == item
                                         ? Color("brand-primary", bundle: .main)
                                         : Color("text-secondary", bundle: .main))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(side == item ? AccessibilityTraits.isButton.union(.isSelected) : .isButton)
                .accessibilityIdentifier("bodyMap.side.\(item.rawValue)")
            }
        }
        .padding(3)
        .background(Color("bg-grouped", bundle: .main), in: Capsule())
        .overlay(Capsule().stroke(Color("text-primary", bundle: .main).opacity(0.06), lineWidth: 1))
    }

    private var regionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HealthHistoryCatalog.bodyRegions) { region in
                    Button {
                        selectRegion(region.id)
                    } label: {
                        Text(region.name)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(regionID == region.id
                                        ? Color("brand-primary", bundle: .main).opacity(0.14)
                                        : Color("bg-grouped", bundle: .main),
                                        in: Capsule())
                            .overlay(Capsule().stroke(regionID == region.id
                                                      ? Color("brand-primary", bundle: .main).opacity(0.65)
                                                      : Color("text-primary", bundle: .main).opacity(0.06),
                                                      lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(regionID == region.id
                                     ? Color("brand-primary", bundle: .main)
                                     : Color("text-primary", bundle: .main))
                    .accessibilityAddTraits(regionID == region.id ? AccessibilityTraits.isButton.union(.isSelected) : .isButton)
                    .accessibilityIdentifier("bodyMap.region.\(region.id)")
                }
            }
        }
    }

    private func organChips(_ region: HealthHistoryCatalog.BodyRegion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.healthHistoryChooseOrgan)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color("text-secondary", bundle: .main))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleOrgans(region)) { organ in
                        OrganChip(organ: organ, selected: organID == organ.id) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                organID = organ.id
                            }
                        }
                    }
                }
            }
        }
    }

    private func visibleOrgans(_ region: HealthHistoryCatalog.BodyRegion)
        -> [HealthHistoryCatalog.BodyOrgan] {
        let ids = Set(OrganLayout.placements(regionID: region.id, gender: gender).map(\.id))
        return region.organs.filter { ids.contains($0.id) }
    }

    private func selectRegion(_ id: String) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.88)) {
            if id == "back" {
                side = .back
            } else if ["chest", "abdomen", "pelvis"].contains(id) {
                side = .front
            }
            regionID = id
            organID = nil
            zoomedRegionID = id
        }
        DispatchQueue.main.async {
            zoomedFocus = id
        }
    }
}

/// 全身剪影 + 一级部位命中区。
struct FullBodyAnatomyView: View {
    let side: AnatomyBodySide
    let selectedRegionID: String?
    let onSelect: (String) -> Void

    private var hotspotIDs: [String] {
        side == .front
            ? ["head_neck", "chest", "abdomen", "pelvis", "upper_limb", "lower_limb"]
            : ["head_neck", "back", "upper_limb", "lower_limb"]
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [
                        Color("surface-tint-start", bundle: .main).opacity(0.58),
                        Color("surface-tint-end", bundle: .main).opacity(0.28),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color("text-primary", bundle: .main).opacity(0.05), lineWidth: 1)
                    )

                HumanBodyShape(side: side)
                    .fill(LinearGradient(colors: [
                        Color("text-primary", bundle: .main).opacity(0.14),
                        Color("text-primary", bundle: .main).opacity(0.07),
                    ], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        HumanBodyShape(side: side)
                            .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
                    )
                    .shadow(color: Color("text-primary", bundle: .main).opacity(0.10),
                            radius: 10, y: 4)

                BodySurfaceDetails(side: side)
                    .stroke(Color("text-primary", bundle: .main).opacity(0.18),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                ForEach(hotspotIDs, id: \.self) { id in
                    Button {
                        onSelect(id)
                    } label: {
                        BodyRegionShape(regionID: id, side: side)
                            .fill(selectedRegionID == id
                                  ? Color("brand-primary", bundle: .main).opacity(0.20)
                                  : Color.clear)
                            .overlay(
                                BodyRegionShape(regionID: id, side: side)
                                    .stroke(selectedRegionID == id
                                            ? Color("brand-primary", bundle: .main)
                                            : Color.clear,
                                            lineWidth: 1.5)
                            )
                            .contentShape(BodyRegionShape(regionID: id, side: side))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(regionName(id))
                    .accessibilityHint(L10n.healthHistoryTapRegion)
                    .accessibilityAddTraits(selectedRegionID == id
                                            ? AccessibilityTraits.isButton.union(.isSelected)
                                            : .isButton)
                    .accessibilityIdentifier("bodyMap.region.\(id)")
                }
            }
            .frame(width: min(size.width, size.height * 0.66), height: size.height)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 292)
    }

    private func regionName(_ id: String) -> String {
        HealthHistoryCatalog.bodyRegions.first { $0.id == id }?.name ?? id
    }
}
