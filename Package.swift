// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "iyf",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "iyf-alert", targets: ["IYFAlert"]),
    ],
    targets: [
        .target(name: "IYFAlertCore"),
        .executableTarget(
            name: "IYFAlert",
            dependencies: ["IYFAlertCore"]
        ),
        .testTarget(
            name: "IYFAlertCoreTests",
            dependencies: ["IYFAlertCore"]
        ),
    ]
)
