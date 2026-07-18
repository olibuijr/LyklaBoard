// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LemmaCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LemmaCore", targets: ["LemmaCore"]),
        .executable(name: "lemma-bench", targets: ["lemma-bench"]),
    ],
    targets: [
        .target(
            name: "LemmaCore"
        ),
        .executableTarget(
            name: "lemma-bench",
            dependencies: ["LemmaCore"]
        ),
        .testTarget(
            name: "LemmaCoreTests",
            dependencies: ["LemmaCore"],
            resources: [
                .copy("Resources/bin-morph.core.bin"),
                .copy("Resources/lemmatize-fixture.json"),
            ]
        ),
    ],
    // swift-tools-version 6.0 is required to express `.iOS(.v18)` as a
    // platform (added in PackageDescription 6.0). Pinning the language mode
    // to v5 keeps the existing Swift 5 semantics (no Swift 6 strict
    // concurrency checking) so this stays a pure platform-floor bump, not a
    // concurrency-model migration.
    swiftLanguageModes: [.v5]
)
