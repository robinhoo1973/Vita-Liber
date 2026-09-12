import Foundation
import Domain

/// FR17.15（业主 2026-09-12）：构建期信任锚的加载入口。
///
/// 资源来源：`Resources/TrustedModelHashes.json`（随 App 包嵌入；由发布者本地工具
/// `refactor/scripts/generate-trusted-hashes.sh`（不入库）从仓库索引固化并提交，
/// 编译期 preBuildScripts 做漂移校验）。
/// 加载失败/资源缺失/结构版本未知 → 空表（**fail closed**：一切运行时下载被拒绝，
/// 已有随包资产与识别功能不受影响）。
public struct TrustedModelHashStore: Sendable {
    public static let resourceName = "TrustedModelHashes"

    public let hashes: TrustedModelHashes

    public init(bundle: Bundle = .main) {
        self.init(url: bundle.url(forResource: Self.resourceName, withExtension: "json"))
    }

    /// 测试/工具链可直接从文件加载（Linux 侧单测、构建脚本校验共用）。
    public init(url: URL?) {
        guard let url, let data = try? Data(contentsOf: url),   // try?-ok: 资源缺失=空表（fail closed），非错误吞没
              let decoded = try? JSONDecoder().decode(TrustedModelHashes.self, from: data) else {   // try?-ok: 解码失败同上
            self.hashes = .empty
            return
        }
        self.hashes = decoded.schemaVersion == TrustedModelHashes.supportedSchemaVersion ? decoded : .empty
    }

    /// 进程级共享实例（Bundle 资源不可变，首次加载后缓存）。
    public static let shared = TrustedModelHashStore()

    public func isTrusted(_ release: ASRModelRelease) -> Bool { hashes.isTrusted(release) }

    public func trustedEntry(for release: ASRModelRelease) -> TrustedModelHashes.Entry? {
        guard hashes.isTrusted(release) else { return nil }
        return hashes.entry(id: release.id, version: release.version)
    }
}
