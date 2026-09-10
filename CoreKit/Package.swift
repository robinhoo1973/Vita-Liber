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
                 revision: "5e4232db78d0150801ae3244c9e2ddc41e5e02d8")
        // 钉版依据（CI 3444xxxxxx 三轮连续实证）：上游 2026-08 起把包装器
        // 连续推前于二进制三次——f2b550d compute_confidence、3e40933
        // window_shift_ratio、42a2b68 attenuation_limit_db（均「extra
        // argument」编译红，其 Package.swift 仍引用旧版二进制）。
        // 5e4232d（2026-07-30，#3828「Add missing files for SPM」）：三字段
        // 均无、配 v1.13.4 二进制；本仓引擎使用的全部 sherpa API 符号已
        // 逐一核对在位。上游重发一致二进制前保持此钉版，升级须重跑符号核对。
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
