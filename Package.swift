// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "linkboy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/nesevis/exhaust", exact: "1.9.0"),
        .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "LinkboyCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "Linkboy", dependencies: ["LinkboyCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "LinkboyCoreTests", dependencies: [
            "LinkboyCore",
            .product(name: "Exhaust", package: "exhaust"),
            .product(name: "Clocks", package: "swift-clocks"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
