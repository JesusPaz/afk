// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AFK",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AFKCore", targets: ["AFKCore"]),
        .library(name: "AFKHost", targets: ["AFKHost"]),
        .executable(name: "afk-host", targets: ["AFKHostCLI"])
    ],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "AFKCore", path: "packages/AFKCore/Sources/AFKCore"),
        .target(name: "AFKHost", dependencies: ["AFKCore", "SwiftTerm"], path: "packages/AFKHost/Sources/AFKHost"),
        .executableTarget(name: "AFKHostCLI", dependencies: ["AFKHost", "AFKCore"], path: "apps/host-cli"),
        .testTarget(name: "AFKCoreTests", dependencies: ["AFKCore"], path: "packages/AFKCore/Tests/AFKCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
