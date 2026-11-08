// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "T3Mini",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "T3Mini", targets: ["T3Mini"]),
        .executable(name: "t3mini-check", targets: ["t3mini-check"]),
    ],
    targets: [
        .target(
            name: "T3MiniCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "T3Mini",
            dependencies: ["T3MiniCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(
            name: "t3mini-check",
            dependencies: ["T3MiniCore"]
        ),
    ]
)
