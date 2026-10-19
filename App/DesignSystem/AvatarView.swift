import SwiftUI
import UIKit
import Perception

/// 用户头像（2026-10-19）：有自选照片显示照片，否则显示预设 SF Symbol。
/// token-only；圆形裁剪；调用方决定尺寸与 a11y 标签。
struct AvatarView: View {
    @Environment(AvatarState.self) private var avatar
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image = avatar.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: avatar.symbol)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(Color("brand-primary", bundle: .main))
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(Color("brand-primary", bundle: .main).opacity(0.14)))
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// 助手头像（固定身份，不随用户设置变化）。
struct AssistantAvatarView: View {
    @Environment(AvatarState.self) private var avatar
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: avatar.assistantSymbol)
            .resizable()
            .scaledToFit()
            .padding(size * 0.22)
            .foregroundStyle(Color("brand-primary", bundle: .main))
            .frame(width: size, height: size)
            .background(Circle().fill(Color("brand-primary", bundle: .main).opacity(0.14)))
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
