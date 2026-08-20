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
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"])
            ]
        ),
        .target(
            name: "LumiCore",
            dependencies: ["CSQLite"],
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
