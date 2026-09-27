import Foundation

/// 测试夹具路径解析（Mac 本地 Xcode 27 实证 2026-09-27 + 委员会批次）：
/// Xcode 27/SPM 6.4 起测试资源嵌套在 `bundle/Contents/Resources/Fixtures/` 内
/// （CI 的 Xcode 26 为平铺 `bundle/Fixtures/`）——两布局探测取命中者，前向兼容
/// 未来 CI 工具链迁移；探测不到时回退平铺路径（失败响亮）。
/// 注意：仅允许在**运行时**调用（测试函数内或计算属性中）——Linux corelibs 上
/// static let 静态初始化期调用跨文件 Foundation API 会触发初始化竞态（本仓
/// 2026-09-27 SIGSEGV 实证，隔离还原后复绿）。
enum TestFixtures {
    static func path(_ relative: String = "") -> String {
        let suffix = relative.isEmpty ? "" : "/" + relative
        let flat = Bundle.module.bundlePath + "/Fixtures" + suffix
        let nested = Bundle.module.bundlePath + "/Contents/Resources/Fixtures" + suffix
        return FileManager.default.fileExists(atPath: nested) ? nested : flat
    }
}
