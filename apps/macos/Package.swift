// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumiDesktop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LumiDesktop", targets: ["LumiDesktop"])
    ],
    targets: [
        .executableTarget(name: "LumiDesktop")
    ]
)
