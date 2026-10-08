// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CopycatCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CopycatCore", targets: ["CopycatCore"])],
    targets: [
        .target(name: "CopycatCore"),
        .testTarget(name: "CopycatCoreTests", dependencies: ["CopycatCore"]),
    ]
)
