// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "CoreKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CoreKit", targets: ["Domain", "Infrastructure"])],
    targets: [
        .target(name: "Domain"),
        .target(name: "Infrastructure", dependencies: ["Domain"]),
        .testTarget(name: "CoreKitTests", dependencies: ["Domain", "Infrastructure"])
    ]
)
// Sprint-2 待办：接入 GRDB 6.x（Linux 需自带 CSQLite 或升级系统 libsqlite3-dev ≥3.31，
// 因 WALSnapshot 依赖 sqlite3_snapshot_cmp；见 M0 计划 §3.1）
