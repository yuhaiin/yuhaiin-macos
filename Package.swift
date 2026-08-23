// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YuhaiinMacOS",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "YuhaiinMacOS", targets: ["YuhaiinMacOS"]),
        .executable(name: "YuhaiinSupervisor", targets: ["YuhaiinSupervisor"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0")
    ],
    targets: [
        .target(name: "YuhaiinShared"),
        .executableTarget(
            name: "YuhaiinMacOS",
            dependencies: [
                "YuhaiinShared",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "YuhaiinSupervisor",
            dependencies: ["YuhaiinShared"]
        )
    ]
)
