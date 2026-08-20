// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiMac",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../../Packages/LumiCore")
    ],
    targets: [
        .executableTarget(
            name: "LumiMac",
            dependencies: [
                .product(name: "LumiCore", package: "LumiCore")
            ]
        )
    ]
)
