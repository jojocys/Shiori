// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shiori",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Shiori", targets: ["Shiori"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Shiori",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "ShioriTests",
            dependencies: ["Shiori"],
            path: "Tests"
        )
    ]
)
