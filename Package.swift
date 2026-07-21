// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EncameraCore",
    defaultLocalization: "en",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .library(
            name: "EncameraCore",
            targets: ["EncameraCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", .upToNextMajor(from: "0.9.1")),
        .package(url: "https://github.com/ZipArchive/ZipArchive.git", .upToNextMajor(from: "2.6.0")),
    ],
    targets: [
        .target(
            name: "EncameraCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "ZipArchive", package: "ZipArchive")
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "EncameraCoreTests",
            dependencies: ["EncameraCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
