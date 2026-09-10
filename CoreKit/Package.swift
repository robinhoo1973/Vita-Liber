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
                 revision: "42a2b681baab87169770b3f829b592e05d5bd2c8")
        // 钉版依据（CI 3444xxxxxx 连续实证）：master/6f5327b 含 2026-09-08
        // f2b550d 的 compute_confidence、3e40933 含 window_shift_ratio——
        // 两个提交都把包装器推前而其二进制仍是旧版（「extra argument」编译红）。
        // 42a2b68（2026-08-10）：两字段均无、配 v1.13.4 二进制；本仓引擎
        // 使用的全部 sherpa API 符号已逐一核对在位。上游重发一致二进制前
        // 保持此钉版，升级时须重跑符号核对。
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
