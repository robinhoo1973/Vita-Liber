#if os(iOS) || os(macOS)
// linux-blind: CryptoKit Ed25519 验签（Apple 专属模块，Linux 不可用） —— Linux 型检编译空单元，改动须经 macOS CI 验证
import CryptoKit
import Foundation

/// medical-data 独立信任链的 CryptoKit 验签器。pinned root 在构造时由 App bundle 固定，
/// `verify` 不接收任何网络给出的 trust root；App 永不加载私钥。
/// 签名只针对 payload 原始字节，解码后的字段绝不重序列化再验。
public struct CryptoKitMedicalCatalogTrustVerifier: MedicalCatalogTrustVerifying, Sendable {
    private let pinnedRootJSON: Data
    private let now: @Sendable () -> Date

    public init(pinnedRootJSON: Data, now: @escaping @Sendable () -> Date = { Date() }) {
        self.pinnedRootJSON = pinnedRootJSON
        self.now = now
    }

    public func verify(catalogJSON: Data, expected: MedicalCatalogSignedExpectation) throws {
        try Self.evaluator.verify(pinnedRootJSON: pinnedRootJSON, catalogJSON: catalogJSON,
                                  expected: expected, now: now())
    }

    static let evaluator = MedicalCatalogTrustEvaluator(
        hasher: CryptoKitContentHasher(),
        isValidSignature: { signature, payload, publicKey in
            do {
                return try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
                    .isValidSignature(signature, for: payload)
            } catch {
                return false
            }
        })
}
#endif
