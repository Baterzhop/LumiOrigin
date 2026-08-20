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
        .target(
            name: "LumiMacSupport",
            dependencies: [
                .product(name: "LumiCore", package: "LumiCore")
            ]
        ),
        .executableTarget(
            name: "LumiMac",
            dependencies: [
                .product(name: "LumiCore", package: "LumiCore"),
                "LumiMacSupport"
            ]
        ),
        .testTarget(
            name: "LumiMacSupportTests",
            dependencies: [
                .product(name: "LumiCore", package: "LumiCore"),
                "LumiMacSupport"
            ]
        )
    ]
)
