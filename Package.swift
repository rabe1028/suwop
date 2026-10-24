// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
#if os(macOS)
    let nativeTarget: Target = .binaryTarget(name: "CSuwop", path: "Generated/RustCore.xcframework")
    let linkSettings: [LinkerSetting] = []
#else
    let nativeTarget: Target = .systemLibrary(name: "CSuwop", path: "Sources/CSuwop")
    let linkSettings: [LinkerSetting] = [.unsafeFlags([root + "/target/debug/libsuwop_ffi.a"])]
#endif

let package = Package(
    name: "Suwop",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SuwopShell", targets: ["SuwopShell"])],
    dependencies: [.package(url: "https://github.com/google-ai-edge/LiteRT-LM.git", exact: "0.18.0")],
    targets: [
        nativeTarget,
        .target(name: "SuwopShell", dependencies: ["CSuwop", .product(name: "LiteRTLM", package: "LiteRT-LM")], linkerSettings: linkSettings),
        .testTarget(name: "SuwopShellTests", dependencies: ["SuwopShell"], resources: [.copy("Fixtures")]),
    ]
)
