// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "iyf",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "iyf-alert", targets: ["IYFAlert"]),
        .executable(name: "iyf-menubar", targets: ["IYFMenuBar"]),
    ],
    targets: [
        .target(name: "IYFAlertCore"),
        .executableTarget(
            name: "IYFAlert",
            dependencies: ["IYFAlertCore"]
        ),
        .executableTarget(name: "IYFMenuBar"),
        .testTarget(
            name: "IYFAlertCoreTests",
            dependencies: ["IYFAlertCore"]
        ),
    ]
)
