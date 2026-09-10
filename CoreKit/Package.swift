// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoreKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "CoreKit", targets: ["Domain", "Protocols", "Infrastructure"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        // 供应链纪律（tech-spec §2.2 准入清单④）：锁定 revision，禁止 branch: master
        // 漂移——sherpa-onnx master 的 binaryTarget 版本/校验和随上游推进变化，
        // 未钉版会让绿色流水线因上游变更无故转红
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git",
                 revision: "6f5327bad87a18ee7dec59b9d3a2b10435189cf3")
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
                         condition: .when(platforms: [.iOS])),
                .product(name: "sherpa-onnx", package: "sherpa-onnx")
            ]),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["Domain", "Protocols", "Infrastructure"],
            resources: [.copy("Fixtures")])
    ],
    cxxLanguageStandard: .cxx17
)
