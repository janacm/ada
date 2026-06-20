// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ada",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "ada-alert", targets: ["ADAAlert"]),
        .executable(name: "ada-menubar", targets: ["ADAMenuBar"]),
    ],
    targets: [
        .target(name: "ADAAlertCore"),
        .executableTarget(
            name: "ADAAlert",
            dependencies: ["ADAAlertCore"]
        ),
        .executableTarget(name: "ADAMenuBar"),
        .testTarget(
            name: "ADAAlertCoreTests",
            dependencies: ["ADAAlertCore"]
        ),
    ]
)
