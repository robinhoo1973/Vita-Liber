import Foundation
import Domain

/// 结构转换登记表（B1，2026-10-29 转换登记表批；两轮四席委员会方案 B+）。
///
/// **权威模型**：定义权威=本文件（git）；执行权威=患者库 `PRAGMA user_version`
/// （SchemaMigrations 单一账本，不迁 GRDB DatabaseMigrator——双账本已否决）。
/// 历史库投影（SchemaHistorySeed）、CI JSON 视图（.github/config/gates/
/// schema-registry.json）与 JSONL 启动收据都是**派生证据**，不得反过来驱动决策。
///
/// **双类行、类型分离**（防 v49 反模式——文件搬移借版本号行会诱导进迁移 runner）：
/// - `.schema` 行 = 版本对行（SchemaMigrations.Step），只喂 GRDBStore 迁移引擎；
/// - `.relocation` 行 = 文件名对行（无版本号），只喂启动路径解析
///   （AppContainer.resolveDatabasePath → DatabaseFileMigration），恒先于 open。
///
/// **硬约束**（L0 与测试断言）：
/// 1. `.relocation` 禁入 GRDBStore.swift（grep 门）；执行点只许在路径解析期；
/// 2. 更名前置=目标不存在；后置=目标存在且 header 有效且 size≠0（DatabaseFileMigration 内建）；
/// 3. 目标目录恒等于源目录（同卷 rename(2) 原子；跨卷退化为拷贝已判定死场景）；
/// 4. 名字 lowercase 唯一（大小写不敏感卷互吞防护）；
/// 5. 步序只许追加（版本严格递增，v17 空号保留）。
public enum DatabaseConversion {
    case schema(SchemaMigrations.Step)
    case relocation(Relocation)

    /// 文件名对行：把 oldName 原子改名为 newName（单文件患者库场景）。
    public struct Relocation: Sendable, Equatable {
        public let oldName: String
        public let newName: String
        /// 执行体符号（启动路径解析期调用；L0 断言其存在于 DatabaseFileMigration）。
        public let executor: String
        /// 读到新名所需的最低 App 版本登记（旧二进制只认旧名→打开新名会当
        /// fresh 建空库；当前为 nil=改名先于任何旧二进制可读新名场景，
        /// 预留字段，出现跨版本并行部署时启用）。
        public let minBinaryVersion: String?

        public init(oldName: String, newName: String, executor: String,
                    minBinaryVersion: String? = nil) {
            self.oldName = oldName; self.newName = newName
            self.executor = executor; self.minBinaryVersion = minBinaryVersion
        }
    }

    /// 登记表全集：所有 schema 步 + 文件名对行（顺序=申报顺序；`.schema` 按版本升序）。
    public static let all: [DatabaseConversion] =
        SchemaMigrations.steps.map(DatabaseConversion.schema) + [
            // vitaliber.sqlite → app-local-user_data.sqlite（2026-10-25 三段落命名规范）。
            // 单命中时由 resolveDatabasePath 在 open 前原子改名；并存 → fail-closed。
            .relocation(Relocation(oldName: PatientDatabaseNames.legacy,
                                   newName: PatientDatabaseNames.canonical,
                                   executor: "DatabaseFileMigration.migrate")),
        ]

    /// 登记表一致性自检（测试与 L0 共用口径；返回违规清单，空=合规）。
    public static func violations() -> [String] {
        var issues: [String] = []
        let steps = SchemaMigrations.steps
        // 版本严格递增（允许 v17 空号，但不许回退/重复）。
        for (lhs, rhs) in zip(steps, steps.dropFirst()) where lhs.version >= rhs.version {
            issues.append("版本非严格递增: v\(lhs.version) → v\(rhs.version)")
        }
        for step in steps {
            if step.sql.isEmpty, step.executor == nil {
                issues.append("v\(step.version) \(step.name): code 步缺 executor 符号")
            }
            if !step.sql.isEmpty, step.hasCode, step.executor == nil {
                issues.append("v\(step.version) \(step.name): hybrid 步缺 executor 符号")
            }
        }
        // 文件名对行：名字 lowercase 唯一 + 与 schema 行无关。
        var seen: Set<String> = []
        for row in all {
            guard case .relocation(let relocation) = row else { continue }
            for name in [relocation.oldName, relocation.newName] {
                if !seen.insert(name.lowercased()).inserted {
                    issues.append("文件名重复声明: \(name)")
                }
            }
        }
        return issues
    }
}
