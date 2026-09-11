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
        // 包装器/二进制匹配的钉版；ITMS-90208在归档的framework元数据校正及IPA校验处处理。
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git",
                 revision: "5e4232db78d0150801ae3244c9e2ddc41e5e02d8"),
        // 上游为branch依赖，根包显式钉住ORT资产版本，防传递依赖静默漂移。
        .package(url: "https://github.com/csukuangfj/onnxruntime-libs",
                 revision: "2ece6a6d72b6667d69f33f05b417ebed079f226a")
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
