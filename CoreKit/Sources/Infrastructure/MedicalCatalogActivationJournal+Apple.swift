#if os(iOS) || os(macOS)
// linux-blind: StreamingFileHasher(CryptoKit)/MedicalCatalogStore(GRDB) 生产装配 —— Linux 型检编译空单元，改动须经 macOS CI 验证
import Foundation

public extension MedicalCatalogActivationJournal {
    static let journalFileName = "medical-catalog-activation.journal.json"

    /// 生产装配：真实流式 CryptoKit SHA-256 + GRDB `catalog_meta`/`user_version` 复核门。
    /// App 侧只需传目录库支持目录（`destination` 所在目录），journal 文件名固定。
    static func production(supportDirectory: URL) -> MedicalCatalogActivationJournal {
        MedicalCatalogActivationJournal(
            journalURL: supportDirectory.appendingPathComponent(journalFileName),
            supportDirectory: supportDirectory,
            sha256: { try StreamingFileHasher.sha256(of: $0) },
            verifyStorage: { path, expected in
                _ = try MedicalCatalogReadAccess.prepare(path: path, expected: expected)
            })
    }
}
#endif
