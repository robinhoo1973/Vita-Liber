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
