// swift-tools-version:5.9
import PackageDescription
import Foundation
let spikeDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // Package.swift -> Spike/
let repoRoot = spikeDir.deletingLastPathComponent()
let vendorInclude = repoRoot
    .appendingPathComponent("Vendor/Ghostty/build/include").path
let vendorLibDir = repoRoot
    .appendingPathComponent("Vendor/Ghostty/build/lib").path

// The main product package (TerminalKit + GhosttyBridge) lives next door.
let mainPackage = repoRoot.appendingPathComponent("Packages").path

let frameworks: [String] = [
    "-framework", "Metal",
    "-framework", "CoreVideo",
    "-framework", "CoreFoundation",
    "-framework", "CoreGraphics",
    "-framework", "CoreText",
    "-framework", "Foundation",
    "-framework", "IOSurface",
    "-framework", "QuartzCore",
    "-framework", "Carbon",
]

let linkGhostty: [LinkerSetting] = [
    .unsafeFlags(["-L\(vendorLibDir)", "-lghostty-internal", "-lc++"] + frameworks)
]

let package = Package(
    name: "Spike",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Real TerminalKit types for the stage-3 live verification.
        .package(path: mainPackage),
    ],
    targets: [
        .target(
            name: "CGhostty",
            path: "Sources/CGhostty"
        ),
        .executableTarget(
            name: "spike-harness",
            dependencies: ["CGhostty"],
            path: "Sources/spike-harness",
            linkerSettings: linkGhostty
        ),
        .executableTarget(
            name: "spike-threadprobe",
            dependencies: ["CGhostty"],
            path: "Sources/spike-threadprobe",
            linkerSettings: linkGhostty
        ),
        .executableTarget(
            name: "spike-terminalkit",
            dependencies: [
                "CGhostty",
                .product(name: "TerminalKit", package: "Packages"),
            ],
            path: "Sources/spike-terminalkit",
            linkerSettings: linkGhostty
        ),
    ]
)
