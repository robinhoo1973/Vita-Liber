import SwiftUI
import Domain

/// FR10.6「去挂号」深链卡（ui-ux §5.39）：复诊提醒详情按医院名匹配
/// **本地**映射表（HospitalDeepLinkRegistry.defaults，无服务端查询），
/// 一键跳平台搜索页；返回后手动补录预约编号。不内嵌交易、不抽佣。
///
/// 规则全在 Domain（精确匹配 → 模糊降级 → 无条目给手输补录），本层只渲染。
struct AppointmentDeepLinkCard: View {
    let hospital: String
    var onCommitBookingNo: ((String) -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var bookingNo = ""

    private var entry: HospitalDeepLink? {
        HospitalDeepLinkRegistry.link(for: hospital,
                                      in: HospitalDeepLinkRegistry.defaults)
            ?? HospitalDeepLinkRegistry.fuzzyLink(for: hospital,
                                                  in: HospitalDeepLinkRegistry.defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VLIcon.hospital.resizable().frame(width: 20, height: 20)
                Text(L10n.deeplink_title).font(.headline)
            }
            if let entry {
                Text(L10n.deeplinkJump(entry.hospitalName))
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    guard let url = URL(string: entry.url(bookingNo: "")) else { return }
                    openURL(url)
                } label: {
                    HStack(spacing: 6) {
                        VLIcon.externalLink.resizable().frame(width: 16, height: 16)
                        Text(L10n.deeplinkOpen(entry.hospitalName))
                    }
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("FR10.6.deepLink.open")
            } else {
                Text(L10n.deeplink_notFound)
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 返回后手动补录预约编号（FR10.6：不内嵌交易）
            TextField(L10n.deeplink_bookingNo, text: $bookingNo)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("FR10.6.bookingNo.input")
            if let onCommitBookingNo, !bookingNo.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(L10n.deeplink_saveNo) {
                    onCommitBookingNo(bookingNo.trimmingCharacters(in: .whitespaces))
                    bookingNo = ""
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("FR10.6.bookingNo.save")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color("bg-grouped", bundle: .main)))
        .accessibilityIdentifier("FR10.6.deepLink.card")
    }
}
