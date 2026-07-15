// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lexicon",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Lexicon", targets: ["Lexicon"]),
        .executable(name: "lex-bench", targets: ["lex-bench"]),
    ],
    targets: [
        .target(
            name: "Lexicon"
        ),
        .executableTarget(
            name: "lex-bench",
            dependencies: ["Lexicon"]
        ),
        .testTarget(
            name: "LexiconTests",
            dependencies: ["Lexicon"],
            resources: [
                .copy("Resources/fixture.lex")
            ]
        ),
    ],
    // swift-tools-version 6.0 is required to express `.iOS(.v18)` as a
    // platform (added in PackageDescription 6.0). Pinning the language mode
    // to v5 keeps existing Swift 5 semantics (no Swift 6 strict concurrency
    // checking) so this stays a pure platform-floor bump, not a concurrency
    // migration — mirrors Packages/LemmaCore/Package.swift.
    swiftLanguageModes: [.v5]
)
