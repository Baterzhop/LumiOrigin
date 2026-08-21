// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumiDesktop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LumiClientCore", targets: ["LumiClientCore"]),
        .executable(name: "LumiDesktop", targets: ["LumiDesktop"])
    ],
    targets: [
        .target(
            name: "LumiClientCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(name: "LumiDesktop", dependencies: ["LumiClientCore"]),
        .testTarget(name: "LumiClientCoreTests", dependencies: ["LumiClientCore"])
    ]
)
