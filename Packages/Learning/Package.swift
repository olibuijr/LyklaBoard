// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Learning",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Learning", targets: ["Learning"]),
    ],
    dependencies: [
        // For the `Lexicon` protocol only — `PersonalLexicon` conforms so the
        // engine can blend the personal model as a third suggestion source
        // next to the base is.lex / en.lex readers.
        .package(path: "../Lexicon"),
    ],
    targets: [
        .target(
            name: "Learning",
            dependencies: [
                .product(name: "Lexicon", package: "Lexicon"),
            ]
        ),
        .testTarget(
            name: "LearningTests",
            dependencies: ["Learning"]
        ),
    ],
    // swift-tools-version 6.0 is required to express `.iOS(.v18)` as a
    // platform (added in PackageDescription 6.0). Pinning the language mode
    // to v5 keeps existing Swift 5 semantics (no Swift 6 strict concurrency
    // checking) so this stays a pure platform-floor bump, not a concurrency
    // migration — mirrors Packages/Lexicon/Package.swift.
    swiftLanguageModes: [.v5]
)
