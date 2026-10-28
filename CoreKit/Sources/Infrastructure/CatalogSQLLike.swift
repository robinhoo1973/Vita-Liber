import Foundation

/// SQL LIKE 模式转义（自 v4 `MedicalReferenceCatalogStore.likeEscaped` 原样搬出）：
/// `\` `%` `_` 按 ESCAPE '\' 语义先行转义。切片三 Store 共用；DDL 查询统一 ESCAPE。
enum CatalogSQLLike {
    static func escaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if c == "\\" || c == "%" || c == "_" {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }
}
