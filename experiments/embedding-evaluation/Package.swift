// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmbeddingEvaluation",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "EmbeddingProbe", dependencies: [.product(name: "SuwopShell", package: "suwop")])]
)
