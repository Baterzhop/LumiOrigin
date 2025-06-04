// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "LumiOrigin",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "LumiOriginApp", targets: ["LumiOrigin"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "LumiOrigin",
            path: ".",
            exclude: [],
            sources: ["."],
            resources: []
        )
    ]
)
