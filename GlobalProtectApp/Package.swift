// swift-tools-version: 6.0
import PackageDescription

// GlobalProtectCore holds everything that does not need AppKit/SwiftUI: the
// models, the gpclient command builder and output parser, process plumbing and
// the bridge that drives gpclient. It builds and tests on Linux, which is what
// CI runs in a container. The GlobalProtect app target (SwiftUI, Keychain,
// menu bar) is macOS only and is skipped when the package is built elsewhere.

var targets: [Target] = [
    .target(
        name: "GlobalProtectCore",
        path: "Sources/GlobalProtectCore"
    ),
    .testTarget(
        name: "GlobalProtectCoreTests",
        dependencies: ["GlobalProtectCore"],
        path: "Tests/GlobalProtectCoreTests"
    )
]

var products: [Product] = [
    .library(name: "GlobalProtectCore", targets: ["GlobalProtectCore"])
]

#if os(macOS)
targets += [
    .executableTarget(
        name: "GlobalProtect",
        dependencies: ["GlobalProtectCore"],
        path: "Sources/GlobalProtect",
        resources: [
            .process("Resources")
        ],
        swiftSettings: [
            .enableExperimentalFeature("IsolatedDeinit")
        ]
    ),
    .testTarget(
        name: "GlobalProtectTests",
        dependencies: ["GlobalProtect", "GlobalProtectCore"],
        path: "Tests/GlobalProtectTests"
    )
]
products.append(.executable(name: "GlobalProtect", targets: ["GlobalProtect"]))
#endif

let package = Package(
    name: "GlobalProtect",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
