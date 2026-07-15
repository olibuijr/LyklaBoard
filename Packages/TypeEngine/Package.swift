// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeEngine",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TypeEngine", targets: ["TypeEngine"]),
        .executable(name: "type-eval", targets: ["type-eval"]),
    ],
    dependencies: [
        .package(path: "../LemmaCore"),
        .package(path: "../Lexicon"),
    ],
    targets: [
        .target(
            name: "TypeEngine",
            dependencies: [
                .product(name: "LemmaCore", package: "LemmaCore"),
                .product(name: "Lexicon", package: "Lexicon"),
            ]
        ),
        .executableTarget(
            name: "type-eval",
            dependencies: ["TypeEngine"],
            resources: [
                .copy("Resources/eval-fixture.tsv")
            ]
        ),
        .testTarget(
            name: "TypeEngineTests",
            dependencies: ["TypeEngine"]
        ),
    ],
    // swift-tools-version 6.0 is required to express `.iOS(.v18)` as a
    // platform (added in PackageDescription 6.0). Pinning the language mode
    // to v5 keeps the existing Swift 5 semantics (no Swift 6 strict
    // concurrency checking) so this stays a pure platform-floor bump, not a
    // concurrency-model migration.
    swiftLanguageModes: [.v5]
)
