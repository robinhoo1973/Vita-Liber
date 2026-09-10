// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoreKit",
    // macOS 14 必须保留：CoreKit swift test（484 测）在 macOS runner 真实执行
    // （业主 2026-09-06 决定）；去掉后 SPM 按 tools-version 默认 10.13 解析，
    // 与 sherpa-onnx 的 macos 10.15 平台下限冲突（CI 344410xxxx 实证）。
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CoreKit", targets: ["Domain", "Protocols", "Infrastructure"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        // 供应链纪律（tech-spec §2.2 准入清单④）：锁定 revision，禁止 branch: master
        // 漂移——sherpa-onnx master 的 binaryTarget 版本/校验和随上游推进变化，
        // 未钉版会让绿色流水线因上游变更无故转红
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git",
                 revision: "3e409338959097c6518998c9b72757db257f5f6f")
        // 钉版依据（CI 3444xxxxxx 实证）：master 与 6f5327b 均含 2026-09-08
        // 提交 f2b550d 引入的 compute_confidence 包装器调用，而二进制仍为
        // v1.13.7（头文件无该字段）——「extra argument」编译红。钉到
        // f2b550d 前一提交 3e40933：包装器与二进制一致。
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Protocols", dependencies: ["Domain"]),
        .target(
            name: "Infrastructure",
            dependencies: [
                "Domain",
                "Protocols",
                // GRDB：iOS 与 macOS 都链接（macOS = CoreKit 测试宿主）。
                .product(name: "GRDB", package: "GRDB.swift",
                         condition: .when(platforms: [.iOS, .macOS])),
                // sherpa-onnx：仅 iOS 链接——引擎文件在非 iOS 平台是编译占位
                // （#if os(iOS) 守卫），macOS 测试宿主不下载数百 MB 二进制。
                .product(name: "sherpa-onnx", package: "sherpa-onnx",
                         condition: .when(platforms: [.iOS]))
            ]),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["Domain", "Protocols", "Infrastructure"],
            resources: [.copy("Fixtures")])
    ],
    cxxLanguageStandard: .cxx17
)
