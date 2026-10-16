// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AFKSecureTransportExperiment",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AFKSecureTransport", targets: ["AFKSecureTransport"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
    ],
    targets: [
        .target(name: "AFKSecureTransport", dependencies: [
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
        ]),
        .testTarget(name: "AFKSecureTransportTests", dependencies: [
            "AFKSecureTransport",
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
