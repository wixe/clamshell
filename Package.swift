// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clamshell",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "clamshell",
            targets: ["ClamshellCLI"]
        ),
        .executable(
            name: "ClamshellApp",
            targets: ["ClamshellApp"]
        ),
        .library(
            name: "ClamshellCore",
            targets: ["ClamshellCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ClamshellCore",
            dependencies: [],
            path: "Sources/ClamshellCore"
        ),
        .executableTarget(
            name: "ClamshellCLI",
            dependencies: ["ClamshellCore"],
            path: "Sources/ClamshellCLI"
        ),
        .executableTarget(
            name: "ClamshellApp",
            dependencies: ["ClamshellCore"],
            path: "Sources/ClamshellApp"
        ),
        .testTarget(
            name: "ClamshellTests",
            dependencies: ["ClamshellCore"],
            path: "Tests/ClamshellTests"
        )
    ]
)
