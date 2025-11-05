// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AvoCam",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "AvoCam",
            targets: ["AvoCam"]),
    ],
    dependencies: [
        // SwiftNIO for HTTP/WebSocket server
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.28.0"),
        // WebSocket support
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.14.0"),
    ],
    targets: [
        .target(
            name: "AvoCam",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
            ],
            path: "Sources"
        ),
    ]
)
