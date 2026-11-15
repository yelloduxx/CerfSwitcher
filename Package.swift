// swift-tools-version: 6.0
import PackageDescription
import Foundation

let testHost = ProcessInfo.processInfo.environment["RUSWITCH_TEST_HOST"] == "1"
let applicationEntry = testHost ? "RuSwitcherTestHost" : "RuSwitcherProduction"
let applicationDependencies: [Target.Dependency] = ["RuSwitcherCore", "RuSwitcherAppSupport"]
    + (testHost ? ["RuSwitcherTestSupport"] : [])

let package = Package(
    name: "RuSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RuSwitcherCore", targets: ["RuSwitcherCore"]),
        .executable(name: testHost ? "CerfSwitcherTestHost" : "RuSwitcher", targets: ["RuSwitcher"]),
        .executable(name: "RuSwitcherInputMethod", targets: ["RuSwitcherInputMethod"]),
        .executable(name: "RuSwitcherSimulator", targets: ["RuSwitcherSimulator"]),
        .executable(name: "RuSwitcherTypingSimulator", targets: ["RuSwitcherTypingSimulator"]),
        .executable(name: "RuSwitcherNativeEditorHost", targets: ["RuSwitcherNativeEditorHost"]),
        .executable(name: "RuSwitcherNativeDriver", targets: ["RuSwitcherNativeDriver"]),
    ],
    targets: [
        .target(
            name: "RuSwitcherCore",
            path: "Sources/RuSwitcherCore",
            resources: [
                .process("Resources/language-model-v1.bin"),
            ]
        ),
        .target(
            name: "RuSwitcherAppSupport",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherAppSupport",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(
            name: "RuSwitcher",
            dependencies: applicationDependencies,
            path: "Sources",
            exclude: [
                "RuSwitcherCore", "RuSwitcherAppSupport", "RuSwitcherInputMethod",
                "RuSwitcherSimulator", "RuSwitcherTypingSimulator",
                testHost ? "RuSwitcherProduction" : "RuSwitcherTestHost",
            ],
            sources: ["RuSwitcher", applicationEntry],
            swiftSettings: testHost ? [.define("RUSWITCH_TEST_HOST")] : [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "RuSwitcherInputMethod",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherInputMethod",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("InputMethodKit"),
            ]
        ),
        .executableTarget(
            name: "RuSwitcherSimulator",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherSimulator"
        ),
        .executableTarget(
            name: "RuSwitcherTypingSimulator",
            dependencies: ["RuSwitcherCore", "RuSwitcherAppSupport", "RuSwitcherTestSupport"],
            path: "Sources/RuSwitcherTypingSimulator"
        ),
        .target(
            name: "RuSwitcherTestSupport",
            dependencies: ["RuSwitcherCore", "RuSwitcherAppSupport"],
            path: "Tests/Support"
        ),
        .executableTarget(
            name: "RuSwitcherNativeEditorHost",
            dependencies: ["RuSwitcherAppSupport", "RuSwitcherCore", "RuSwitcherTestSupport"],
            path: "Tests/NativeEditorHost"
        ),
        .executableTarget(
            name: "RuSwitcherNativeDriver",
            dependencies: ["RuSwitcherCore", "RuSwitcherAppSupport", "RuSwitcherTestSupport"],
            path: "Tests/NativeDriver"
        ),
        .testTarget(
            name: "RuSwitcherNativeTests",
            dependencies: ["RuSwitcher", "RuSwitcherAppSupport"],
            path: "Tests/RuSwitcherNativeTests"
        ),
        .testTarget(
            name: "RuSwitcherTypingTests",
            dependencies: ["RuSwitcherTestSupport", "RuSwitcherCore"],
            path: "Tests/RuSwitcherTypingTests"
        ),
        .testTarget(
            name: "RuSwitcherCoreTests",
            dependencies: ["RuSwitcherCore"],
            path: "Tests/RuSwitcherCoreTests"
        ),
        .testTarget(
            name: "RuSwitcherAppSupportTests",
            dependencies: ["RuSwitcherAppSupport", "RuSwitcherCore", "RuSwitcherTestSupport"],
            path: "Tests/RuSwitcherAppSupportTests"
        )
    ]
)
