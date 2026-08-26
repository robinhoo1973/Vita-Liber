// swift-tools-version:5.9
import PackageDescription

// GRDB 平台条件依赖（ERR#8）：Linux 发行版 libsqlite3 未启用 SQLITE_ENABLE_SNAPSHOT，
// 缺 sqlite3_snapshot_* 符号无法链接 GRDB；产品目标平台 iOS 的 SQLite 具备该能力。
// `.when(platforms:)` 使 GRDB 只在 iOS/macOS 参与编译链接——Linux 上仅解析不构建
// （已实测：swift build 不编译 GRDB，无符号错误），Linux CI 继续守 Domain 层门禁。
let package = Package(
    name: "CoreKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CoreKit", targets: ["Domain", "Protocols", "Infrastructure"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Protocols", dependencies: ["Domain"]),
        .target(
            name: "Infrastructure",
            dependencies: [
                "Domain",
                "Protocols",
                .product(name: "GRDB", package: "GRDB.swift",
                         condition: .when(platforms: [.iOS, .macOS]))
            ]),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["Domain", "Protocols", "Infrastructure"],
            resources: [.copy("Fixtures")])
    ]
)
