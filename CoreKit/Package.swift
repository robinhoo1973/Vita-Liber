// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "CoreKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CoreKit", targets: ["Domain", "Infrastructure"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3")],
    targets: [
        .target(name: "Domain"),
        .target(name: "Infrastructure", dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "CoreKitTests", dependencies: ["Domain", "Infrastructure"])
    ]
)
