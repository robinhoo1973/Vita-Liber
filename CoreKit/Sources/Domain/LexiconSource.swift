import Foundation

/// F25 词表证据层端口（2026-09-21，FR25.12⑬）：词表锚定抽取的数据来源。
///
/// 词表 = `code_alias`（有码：指标/药名词，与 CodeResolver 同源）∪
/// `lexicon_term`（无码：药名/剂型/给药途径/频次）——**同一出口**供
/// `LexiconScanner` 扫描；识别侧只做匹配建议（D 级草稿去向由用户裁决，
/// BR-003），词表本身不承载任何事实。
///
/// Domain 自声明端口（`CodeIndex` 先例）；Infrastructure `GRDBCodeIndex` 实现。
public protocol LexiconSource: Sendable {
    /// 全量词表快照（种子装载后调用；调用方自行缓存——词表随 bundle_version 整批替换）。
    func lexiconEntries() async throws -> [LexiconEntry]
}
