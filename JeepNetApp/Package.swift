// swift-tools-version: 6.0
import PackageDescription

// JeepNetCore holds everything that does not need AppKit/SwiftUI: the
// models, the gpclient command builder and output parser, process plumbing and
// the bridge that drives gpclient. It builds and tests on Linux, which is what
// CI runs in a container. The JeepNet app target (SwiftUI, Keychain,
// menu bar) is macOS only and is skipped when the package is built elsewhere.

var targets: [Target] = [
    .target(
        name: "JeepNetCore",
        path: "Sources/JeepNetCore"
    ),
    .testTarget(
        name: "JeepNetCoreTests",
        dependencies: ["JeepNetCore"],
        path: "Tests/JeepNetCoreTests"
    )
]

var products: [Product] = [
    .library(name: "JeepNetCore", targets: ["JeepNetCore"])
]

#if os(macOS)
targets += [
    .executableTarget(
        name: "JeepNet",
        dependencies: ["JeepNetCore"],
        path: "Sources/JeepNet",
        resources: [
            .process("Resources")
        ],
        swiftSettings: [
            .enableExperimentalFeature("IsolatedDeinit")
        ]
    ),
    .testTarget(
        name: "JeepNetTests",
        dependencies: ["JeepNet", "JeepNetCore"],
        path: "Tests/JeepNetTests"
    )
]
products.append(.executable(name: "JeepNet", targets: ["JeepNet"]))
#endif

let package = Package(
    name: "JeepNet",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
