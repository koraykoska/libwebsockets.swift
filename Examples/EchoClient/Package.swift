// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EchoClient",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    dependencies: [
        .package(url: "../../", branch: "master"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.57.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "EchoClient",
            dependencies: [
                .product(name: "libwebsockets", package: "libwebsockets.swift"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources"
        ),
    ]
)
