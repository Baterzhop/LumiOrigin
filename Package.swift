// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumiOrigin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LumiCore", targets: ["LumiCore"]),
        .executable(name: "LumiOrigin", targets: ["LumiOrigin"])
    ],
    targets: [
        .target(
            name: "LumiCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "LumiOrigin",
            dependencies: ["LumiCore"]
        ),
        .testTarget(
            name: "LumiCoreTests",
            dependencies: ["LumiCore"]
        )
    ]
)
