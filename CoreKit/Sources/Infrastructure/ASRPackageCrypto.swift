#if os(iOS) || os(macOS)
// linux-blind: CryptoKit 仅 Apple 平台链接（ERR#8 纪律镜像）—— Linux 型检编译空单元，改动须经 macOS CI 验证
import CryptoKit
import Foundation

/// ASR 下载包加密信封（2026-10-05 业主 R1：包必须加密+压缩）——**ASR 域 façade**。
///
/// 帧格式与 block 解密全部下沉到中性共享核心 `PackageEnvelopeCrypto`
/// （2026-10-07 模块化抽取：ASR/医疗同方案复用，单一出口）；本文件保留三样
/// **不可迁移的 ASR 域契约**：
/// 1. `masterKeyHex` 常量（与 CI secret `ASR_PACKAGE_KEY` 同值）——含 **Python
///    工具链对其源码字面量的正则抓取**（init_asr_secrets.py /
///    test-asr-package-integrity.py 的 `masterKeyHex\s*=\s*"64hex"` 契约），
///    改动此声明形态会断工具链；
/// 2. 身份文法 `identity(id:variant:version:artifactRevision:)`——同版本换内容
///    必须靠 artifactRevision 改变身份（AES-GCM nonce 重放纪律，见 python 正本
///    docstring）；
/// 3. 加密域 namespace `vitaliber/asr/aes256gcm/v1`——与
///    `.github/actions/release/asr_envelope.py` 的 info 串逐字节一致（已发布包与金样
///    `ASREnvelopeGoldenTests` 钉死之字节合同）。
///
/// 轮换语义：主密钥两处（secret/内嵌）同步更新，test-asr-package-integrity.py
/// 断言一致（漏改任何一侧 = 新包解密全灭，fail-closed 但通道全断）。
enum ASRPackageCrypto {
    static let encryptionScheme = "aes256gcm-v1"

    typealias Failure = PackageEnvelopeCrypto.Failure

    /// 加密域 namespace（info 前缀）——与 python 正本逐字节一致，**不得改动**。
    private static let namespace = "vitaliber/asr/aes256gcm/v1"

    /// 主密钥（hex，与 CI secret ASR_PACKAGE_KEY 同值；Python 工具链按此声明形态抓取）。
    private static let masterKeyHex = "2303fac4e6aaacc328f6ac612f77fa91c32594f9c627aab2178b19486ebe7e82"

    static func identity(id: String, variant: String?, version: String, artifactRevision: Int?) -> String {
        let revision = artifactRevision.map { "-r\($0)" } ?? ""
        return "\(id)-\(variant ?? "")-\(version)\(revision)"
    }

    static func isEnvelope(_ data: Data) -> Bool {
        PackageEnvelopeCrypto.isEnvelope(data)
    }

    /// 信封解密（ASR 域）：解码内嵌主密钥后委托共享核心。
    /// 下载所得字节已按签名目录 sha256 校验后调用；本层只做「信封 → 明文 zip」。
    static func decryptEnvelope(at source: URL, to destination: URL, identity: String,
                                onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) throws {
        let master = try PackageEnvelopeCrypto.decodeHexKey(masterKeyHex)
        try PackageEnvelopeCrypto.decryptEnvelope(at: source, to: destination, identity: identity,
                                                  namespace: namespace, masterKey: master,
                                                  onProgress: onProgress)
    }

    /// 更新通告载荷信封解密（README VL-INDEX 二维码；identity=`update-payload-<64hex>`）。
    /// 与 ASR 域同密钥、同 namespace——载荷是提示面，信任语义与 ASR 包一致；
    /// 明文=单 entry ZIP(payload.json)，App 侧再以 sha256(payload.json)==identity 尾段回验。
    static func decryptUpdatePayloadEnvelope(at source: URL, to destination: URL,
                                             identity: String) throws {
        let master = try PackageEnvelopeCrypto.decodeHexKey(masterKeyHex)
        try PackageEnvelopeCrypto.decryptEnvelope(at: source, to: destination, identity: identity,
                                                  namespace: namespace, masterKey: master,
                                                  onProgress: nil)
    }
}
#endif
