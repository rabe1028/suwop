// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Suwop",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SuwopCore", targets: ["SuwopCore"])],
    targets: [
        .target(name: "SuwopCore"),
        .testTarget(name: "SuwopCoreTests", dependencies: ["SuwopCore"]),
        .testTarget(name: "SuwopIntegrationTests", dependencies: ["SuwopCore"])
    ]
)
