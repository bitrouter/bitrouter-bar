// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BitRouterBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BitRouterBar", targets: ["BitRouterBar"]),
    ],
    targets: [
        .executableTarget(name: "BitRouterBar"),
    ]
)
