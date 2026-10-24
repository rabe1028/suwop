// swift-tools-version: 6.0
import PackageDescription

// Builds from a checkout directory named `suwop`, like experiments/embedding-evaluation.
let package = Package(
    name: "MacBench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../..")],
    targets: [.executableTarget(name: "MacBench", dependencies: [.product(name: "SuwopShell", package: "suwop")])]
)
