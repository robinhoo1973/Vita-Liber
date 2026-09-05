import Foundation

/// 内容哈希端口（ADR-025 成熟实现优先 / dev-pm V3.8 登记的 SHA256→CryptoKit 迁移）。
///
/// 为什么是协议而不是 Domain 内自研：crypto 原语必须复用经审计的平台框架
/// （CryptoKit）——自研 SHA-256 曾长期作为生产去重/审计脱敏的载荷路径，
/// 与 ADR-025「加密原语…一律复用经审计的成熟实现，禁止自研」冲突。
/// 生产实现 = Infrastructure 的 CryptoKitContentHasher；Domain 侧的
/// DuplicateDetectionService 经闭包注入哈希函数（Domain 零框架依赖不变）。
public protocol ContentHashing: Sendable {
    /// SHA-256 十六进制摘要（小写）
    func sha256Hex(_ data: Data) -> String
}
