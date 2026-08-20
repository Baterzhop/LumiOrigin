// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiOneCore",
    products: [
        .library(name: "LumiCore", targets: ["LumiCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "LumiOne/Packages/LumiCore/Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"])
            ]
        ),
        .target(
            name: "LumiCore",
            dependencies: ["CSQLite"],
            path: "LumiOne/Packages/LumiCore/Sources/LumiCore"
        ),
        .testTarget(
            name: "LumiCoreTests",
            dependencies: ["LumiCore"],
            path: "LumiOne/Packages/LumiCore/Tests/LumiCoreTests"
        )
    ]
)
