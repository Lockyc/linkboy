// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "linkboy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "LinkboyCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // FocusProbe.js goes into the app bundle's Resources through `just bundle`, not a SwiftPM resource bundle.
        .executableTarget(name: "Linkboy", dependencies: ["LinkboyCore", .product(name: "Sparkle", package: "Sparkle")],
                          exclude: ["FocusProbe.js"]),
        .testTarget(name: "LinkboyCoreTests", dependencies: ["LinkboyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
