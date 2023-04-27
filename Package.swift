// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EncameraCore",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "EncameraCore",
            targets: ["EncameraCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", .upToNextMajor(from: "0.9.1"))
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
