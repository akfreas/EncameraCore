// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EncameraCore",
    defaultLocalization: "en",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .library(
            name: "EncameraCore",
            targets: ["EncameraCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", .upToNextMajor(from: "0.9.1")),
        .package(url: "https://github.com/PiwikPRO/piwik-pro-sdk-framework-ios", .upToNextMajor(from: "1.2.1")),
    ],
    targets: [
        .target(
            name: "EncameraCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium")
            ],
            resources: [.process("Resources")]
        )
    ]
)
