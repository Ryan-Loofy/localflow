// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LocalFlow", targets: ["LocalFlow"])
    ],
    targets: [
        .executableTarget(
            name: "LocalFlow",
            path: "Sources/LocalFlow"
        )
    ]
)
