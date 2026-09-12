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
        // ZIPFoundation：运行时 ASR 模型包解压（业主 2026-09-12 决定引入运行时下载）。
        // 准入（tech-spec §2.2）：平台框架无公开 zip 解压 API（AppleArchive 不读 zip）；
        // MIT 许可、SPM、无网络/遥测、纯 Swift+zlib；退出成本低（仅在
        // ASRModelDownloadService 一处使用，替换为 AppleArchive 只改该文件）。
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        // 包装器/二进制匹配的钉版；ITMS-90208在归档的framework元数据校正及IPA校验处处理。
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git",
                 revision: "5e4232db78d0150801ae3244c9e2ddc41e5e02d8"),
        // 注意：onnxruntime-libs 是 sherpa-onnx 的传递依赖，其 manifest 用
        // `branch: "master"` 声明——根包不得再用 revision 直接声明同一包身份，
        // 否则同图出现两种 requirement kind（revision vs branch），SwiftPM
        // 解析直接拒绝（CI 34606761907 实证：error: onnxruntime-libs is
        // required using two different revision-based requirements）。
        // 防漂移由 Package.resolved 的 branch 状态钉版承担
        // （{revision + branch: "master"} 对），而非根包声明。
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
                // ZIPFoundation：仅 iOS/macOS 链接（Linux 测试宿主不涉运行时下载）。
                .product(name: "ZIPFoundation", package: "ZIPFoundation",
                         condition: .when(platforms: [.iOS, .macOS])),
                .product(name: "sherpa-onnx", package: "sherpa-onnx",
                         condition: .when(platforms: [.iOS, .macOS]))
            ],
            // Supertonic不支持中文，当前中文TTS仍使用已接线的系统实现。
            exclude: ["SherpaOnnxSpeechSynthesizer.swift"]),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["Domain", "Protocols", "Infrastructure"],
            resources: [.copy("Fixtures")])
    ],
    cxxLanguageStandard: .cxx17
)
