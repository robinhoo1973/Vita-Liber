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
        // ADR-026 Linux/dev 轨道：以 C modulemap 暴露 ONNX Runtime C API（libonnxruntime.so
        // 经 Vendor/onnxruntime/lib + LD_LIBRARY_PATH 在链接/运行时解析，绝不进入 iOS 生产 target）。
        .target(
            name: "COnnxRuntime",
            linkerSettings: [
                .unsafeFlags(["-L", "Vendor/onnxruntime/lib"]),
                .linkedLibrary("onnxruntime")
            ]),
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
            resources: [.copy("Fixtures")]),
        // ADR-026 dev 轨道：Linux 离线 OCR 测试入口（同协议跑 PaddleOCRImageRecognizer，
        // 无 Xcode 也能验证「图片→文本行」链路；模型未捆绑时退化为空结果并提示）。
        //
        // COnnxRuntime 只挂在 OcrCli 上、不进 Infrastructure（评审修正）：
        // 此前 Infrastructure 在 Linux 条件依赖 COnnxRuntime，使 CoreKitTests 测试二进制
        // 链接 libonnxruntime.so.1——一台只有 swift toolchain 的干净 Linux（含 CI 容器）
        // 上 `swift test` 构建成功却加载失败，Domain 门禁名存实亡。推理运行时是 dev 轨
        // 专属能力，OcrCli 直接构造 PaddleOCRImageRecognizer；测试与 App 走 EAL 工厂
        // （Linux 上返回 Stub），二者都不再触碰 onnxruntime。
        .executableTarget(
            name: "OcrCli",
            dependencies: [
                "Domain", "Protocols", "Infrastructure",
                .target(name: "COnnxRuntime", condition: .when(platforms: [.linux]))
            ])
    ]
)
