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
        // ══ sherpa-onnx 主轨：临时退出构建（2026-09-10）══
        // 退出原因：App Store 拒绝三个 build（320.1/321.1/322.1）——
        // ITMS-90208「Invalid Bundle：VitaLiber.app/Frameworks/onnxruntime.framework
        // does not support the minimum OS Version specified in the Info.plist」。
        // 根因（IPA 拆解实证）：Xcode 26 将 onnxruntime-libs 的静态
        // xcframework 转成内嵌 dylib（LC_BUILD_VERSION minos=17.0，SDK 26.5），
        // 而框架 Info.plist 仍为上游的 MinimumOSVersion=15.1——二进制与
        // plist 内部矛盾被 Apple 90208 校验拒绝。非本仓代码可修
        // （静态 framework 形态二进制依赖 + Xcode 26 SPM 处理缺陷）。
        // 复归条件（满足其一）：①上游 onnxruntime-libs 发布无该缺陷的
        // 二进制；②Xcode 修复静态 framework 嵌入处理；③改用非 framework
        // 形态（纯 .a）的 onnxruntime 分发。复归步骤：恢复下方依赖/产品/
        // exclude 三项 + EngineFactories 的 sherpa 主轨 + 钉版三问+一复验。
        // .package(url: "https://github.com/k2-fsa/sherpa-onnx.git",
        //          revision: "5e4232db78d0150801ae3244c9e2ddc41e5e02d8")
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
                         condition: .when(platforms: [.iOS, .macOS]))
            ],
            // sherpa 主轨临时退出构建（见上方注释）：引擎文件保留在仓、
            // 移出目标编译，工厂回落基线轨 SFSpeech（功能完备零资产）。
            exclude: ["SherpaOnnxTranscriber.swift", "SherpaOnnxSpeechSynthesizer.swift"]),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["Domain", "Protocols", "Infrastructure"],
            exclude: ["SherpaOnnxEngineTests.swift"],
            resources: [.copy("Fixtures")])
    ],
    cxxLanguageStandard: .cxx17
)
