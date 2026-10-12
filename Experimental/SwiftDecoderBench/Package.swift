// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Measurement harness for the Rust-core comparison. It links the production
// RuSwitcherCore product unchanged and is absent from the root package graph.
// A path dependency's identity is its directory name, which differs between
// the main checkout and worktrees, so it is derived here.
let rootIdentity = URL(fileURLWithPath: Context.packageDirectory)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .lastPathComponent
    .lowercased()

let package = Package(
    name: "SwiftDecoderBench",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "SwiftDecoderBench",
            dependencies: [
                .product(name: "RuSwitcherCore", package: rootIdentity),
            ]
        ),
    ]
)
