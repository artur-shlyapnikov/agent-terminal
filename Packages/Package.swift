// swift-tools-version: 5.10
import Foundation
import PackageDescription

/// Vendored libghostty locations (built by Scripts/build-ghostty-xcframework.sh;
/// run it before building — see Vendor/Ghostty/README.md). Absolute paths are
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// Vendor tree lives at the REPO ROOT, not under Packages/.
let repoRoot = packageDir.deletingLastPathComponent()
let vendorInclude = repoRoot.appendingPathComponent("Vendor/Ghostty/build/include").path
let vendorLibDir = repoRoot.appendingPathComponent("Vendor/Ghostty/build/lib").path

let ghosttyFrameworks: [String] = [
    "-framework", "Metal",
    "-framework", "CoreVideo",
    "-framework", "CoreFoundation",
    "-framework", "CoreGraphics",
    "-framework", "Foundation",
    "-framework", "IOSurface",
    "-framework", "QuartzCore",
    "-framework", "Carbon",
]

/// Linker settings pulling in the pinned static libghostty.
let linkGhostty: [LinkerSetting] = [
    .unsafeFlags(["-L\(vendorLibDir)", "-lghostty-internal", "-lc++"] + ghosttyFrameworks)
]
///
/// Dependency law (architecture notes §3.2), enforceable by inspection of
/// target dependencies and imports:
///
///   AgentCore    → Foundation only
///   AgentStore   → AgentCore + GRDB
///   AgentControl → AgentCore
///   TerminalKit  → AgentCore + AppKit + GhosttyBridge
///   App          → all modules (see App/project.yml)
///   Helpers      → AgentControl protocol models, no AppKit
///
/// Compiler-strictness contract (kept at tools 5.10 until the Swift 6 cutover):
/// every target opts into Swift 6 upcoming features that tighten typing and
/// isolation without changing the language mode; CI treats new warnings as
/// errors. AgentCore additionally pilots `-strict-concurrency=complete`.
///
/// Deliberately deferred to the language-mode cutover (they interact with
/// EVERY Foundation-typed public declaration and default argument):
///   - InternalImportsByDefault   (needs `public import` sweep + API audit)
///   - DisableOutwardActorInference (SE-0405 default-argument visibility)
let typizationSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("RegionBasedIsolation"),
    .enableUpcomingFeature("IsolatedDefaultValues"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("MemberImportVisibility"),
]
let strictConcurrencyPilot: [SwiftSetting] = [
    // unsafeFlags is acceptable here: this package is consumed only by the
    // in-repo app project, never published as a third-party dependency.
    .unsafeFlags(["-strict-concurrency=complete"])
]

let package = Package(
    name: "AgentTerminal",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "GhosttyBridge", targets: ["GhosttyBridge"]),
        .library(name: "TerminalKit", targets: ["TerminalKit"]),
        .library(name: "AgentStore", targets: ["AgentStore"]),
        .library(name: "AgentControl", targets: ["AgentControl"]),
        .executable(name: "AgentLauncher", targets: ["AgentLauncher"]),
        .executable(name: "agentctl", targets: ["agentctl"]),
    ],
    dependencies: [
        // GRDB.swift — MIT licensed, latest stable 7.x.
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.0.0"))
    ],
    targets: [
        // Narrow C ABI over the pinned internal libghostty. Spike gate passed:
        // see docs/Architecture/ADR-0002-libghostty-boundary.md (POINT_SCREEN
        // semantics verified; main-thread-only two-phase teardown policy).
        .target(
            name: "GhosttyBridge",
            cSettings: [
                .unsafeFlags(["-I\(vendorInclude)"])
            ]
        ),
        .target(
            name: "AgentCore",
            resources: [
                .copy("Resources/Detection"),
                .copy("Resources/Integrations")
            ],
            swiftSettings: typizationSettings + strictConcurrencyPilot
        ),
        .target(
            name: "TerminalKit",
            dependencies: ["AgentCore", "GhosttyBridge"],
            swiftSettings: typizationSettings,
            linkerSettings: linkGhostty
        ),
        .target(
            name: "AgentStore",
            dependencies: [
                "AgentCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: typizationSettings
        ),
        .target(
            name: "AgentControl",
            dependencies: ["AgentCore"],
            swiftSettings: typizationSettings
        ),
        .executableTarget(
            name: "AgentLauncher",
            dependencies: ["AgentControl"],
            swiftSettings: typizationSettings
        ),
        .executableTarget(
            name: "agentctl",
            dependencies: ["AgentControl"],
            swiftSettings: typizationSettings
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore"]
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit"],
            linkerSettings: linkGhostty
        ),
        .testTarget(
            name: "AgentLauncherTests",
            dependencies: ["AgentLauncher", "AgentControl"]
        ),
        .testTarget(
            name: "AgentStoreTests",
            dependencies: ["AgentStore"]
        ),
        .testTarget(
            name: "AgentControlTests",
            dependencies: ["AgentControl"]
        ),
    ]
)
