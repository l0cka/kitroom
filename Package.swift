// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Kitroom",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "KitroomCore",
            targets: ["KitroomCore"]
        ),
        .executable(
            name: "Kitroom",
            targets: ["KitroomApp"]
        )
    ],
    targets: [
        .target(
            name: "KitroomCore"
        ),
        .executableTarget(
            name: "KitroomApp",
            dependencies: ["KitroomCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "KitroomCoreTests",
            dependencies: ["KitroomCore"]
        )
    ]
)
