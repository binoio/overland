// swift-tools-version: 6.0
import PackageDescription

// OverlandCore holds everything that does not need AppKit/SwiftUI: the
// models, the gpclient command builder and output parser, process plumbing and
// the bridge that drives gpclient. It builds and tests on Linux, which is what
// CI runs in a container. The Overland app target (SwiftUI, Keychain,
// menu bar) is macOS only and is skipped when the package is built elsewhere.

var targets: [Target] = [
    .target(
        name: "OverlandCore",
        path: "Sources/OverlandCore"
    ),
    // Tiny exec shim used by the privileged wrapper; see Sources/overland-exec/main.swift.
    .executableTarget(
        name: "overland-exec",
        path: "Sources/overland-exec"
    ),
    .testTarget(
        name: "OverlandCoreTests",
        dependencies: ["OverlandCore"],
        path: "Tests/OverlandCoreTests"
    )
]

var products: [Product] = [
    .library(name: "OverlandCore", targets: ["OverlandCore"]),
    .executable(name: "overland-exec", targets: ["overland-exec"])
]

#if os(macOS)
targets += [
    .executableTarget(
        name: "Overland",
        dependencies: ["OverlandCore"],
        path: "Sources/Overland",
        resources: [
            .process("Resources")
        ],
        swiftSettings: [
            .enableExperimentalFeature("IsolatedDeinit")
        ]
    ),
    .testTarget(
        name: "OverlandTests",
        dependencies: ["Overland", "OverlandCore"],
        path: "Tests/OverlandTests"
    )
]
products.append(.executable(name: "Overland", targets: ["Overland"]))
#endif

let package = Package(
    name: "Overland",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
