// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoreKit",
    // macOS 14 必须保留：CoreKit swift test（484 测）在 macOS runner 真实执行
    // （业主 2026-09-06 决定）；去掉后 SPM 按 tools-version 默认 10.13 解析，
    // 与 sherpa-onnx 的 macos 10.15 平台下限冲突（CI 344410xxxx 实证）。
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "CoreKit", targets: ["Domain", "Protocols", "Infrastructure"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        // （swift-perception / xctest-dynamic-overlay 依赖已摘除，结构轮 2026-09-15：
        //  @Perceptible 表现态门面迁入 App 层后 CoreKit 零 UI 观察依赖；App 侧仍直连二者
        //  —— 宏展开的 IssueReporting 链接纪律见 project.yml 注记。）
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
        // T2 本机 LLM 轨恢复（业主 2026-09-17 定：llama 模型**随包内置**）——
        // swift-llama 上游已删（DePasqualeOrg/swift-llama），改用 ggml-org/llama.cpp
        // **自建三切片 XCFramework**：上游 b11012 源码经官方 build-xcframework.sh
        // 构建（上游发布物缺 ios-simulator 切片、L1 模拟器无法链接，CI 35203708914
        // 实证；上游无根 Package.swift 可源码依赖），发布本仓 release
        // `llama-xcframework`；资产按内容寻址命名（llama-<ref>-xcframework-<sha16>.zip），
        // 切换=人工提交本行 URL+checksum（旧资产原地保留可直接回退）。
        // 重建 = testflight.yml 的 llama-xcframework job：每月自动取上游最新 release
        // 重建（schedule），或 dispatch 勾 build_xcframework / llama_ref 回钉（2026-10-09 业主指令）。
        // 准入（tech §2.2）：MIT 许可；官方构建脚本产物（Metal/Accelerate、
        // 无 OpenMP/OpenSSL）；**动态库（MH_DYLIB）内嵌于 App**——ITMS-90208 族风险**适用**，
        // 由 reconcile-frameworks.py 双闸把关（原文「静态库」为错误陈述，2026-10-09 事实更正）；
        // 零网络零遥测；退出成本低（引擎单文件 + 本声明两处）。
        // 平台下限 iOS 16.0（自建切片经 sed 改定并加硬断言）/macOS 13.3——引擎无 #available
        // 守卫，运行时按激活模型就绪降级 T3（2026-10-09 换型批口径，原「16.4 守卫」注记作废）。
        // 校验和 = 发布资产 sha256（SPM binaryTarget 强制）。
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
                // Perception/IssueReporting 依赖已摘除（结构轮 2026-09-15）：@Perceptible 表现态门面
                // （NotificationCenterState/PendingCardCenterState）迁入 App 层——CoreKit 零 UI 观察依赖（P3 分层复位）。
                // ZIPFoundation：仅 iOS/macOS 链接（Linux 测试宿主不涉运行时下载）。
                .product(name: "ZIPFoundation", package: "ZIPFoundation",
                         condition: .when(platforms: [.iOS, .macOS])),
                // AgeKit 已退役（2026-10-07 收尾）：医疗包加密与 ASR 同构为
                // AES-256-GCM 信封，App 侧无任何 import AgeKit；Legacy age 包
                // 由信封 opener 魔数预检响亮拒绝（负例测试钉住）。
                .product(name: "sherpa-onnx", package: "sherpa-onnx",
                         condition: .when(platforms: [.iOS, .macOS])),
                // T2 本机 LLM（业主 2026-09-17 定：llama 模型随包内置）。
                // 模块名 = llama（binaryTarget 的 module map）；引擎代码
                // #if canImport(llama) 守卫——Linux/无框架平台编译为不可用。
                .target(name: "LlamaFramework",
                        condition: .when(platforms: [.iOS, .macOS])),
            ],
            // Supertonic不支持中文，当前中文TTS仍使用已接线的系统实现。
            exclude: ["SherpaOnnxSpeechSynthesizer.swift"]),
        .testTarget(
            name: "CoreKitTests",
            dependencies: [
                "Domain", "Protocols", "Infrastructure",
                // 攻击夹具用成熟库造 ZIP（2026-09-16 委员会评审：解压防御零覆盖）——
                // 与生产解压同源（ZIPFoundation），避免手写 zip 字节造成的假夹具。
                .product(name: "ZIPFoundation", package: "ZIPFoundation",
                         condition: .when(platforms: [.iOS, .macOS])),
            ],
            resources: [.copy("Fixtures")]),
        // T2 本机 LLM（业主 2026-09-17 定：llama 模型随包内置）——
        // binaryTarget 声明于 targets 数组（PackageDescription API：无独立 binaryTargets 参数，
        // CI 35201088924 实证）；模块名 = llama（framework module map）。
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/robinhoo1973/Vita-Liber/releases/download/llama-xcframework/llama-b11012-xcframework.zip",
            // 校验和 = 发布资产 sha256（SPM binaryTarget 强制）。**重建资产必须同步
            // 本值**：2026-10-06 资产消亡后经 build-llama-xcframework.yml 重建
            //（run 37479560076），digest 由 4f1c5182… 更新为 effe9b41…（重建非字节
            // 复现,旧钉值会以 checksum mismatch 红掉一切冷路径——ci-tests 首跑族）。
            // 取新值：gh api repos/robinhoo1973/Vita-Liber/releases/tags/llama-xcframework --jq '.assets[0].digest'
             checksum: "effe9b41632bea2b27ebfc78b1610f8aa8fd5e182e2b8b4d9238073b40eaef21"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
