// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "LumiCore", targets: ["LumiCore"])
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
        .target(name: "LumiCore", dependencies: ["CSQLite"]),
        .testTarget(name: "LumiCoreTests", dependencies: ["LumiCore"])
    ]
)
