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

var dependencies: [Package.Dependency] = []

#if os(macOS)
// Sparkle ships as a binary xcframework, so it is only declared where it can resolve.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"))

targets += [
    // XPC contract + tunnel management shared by the app and the helper.
    .target(
        name: "OverlandHelperShared",
        dependencies: ["OverlandCore"],
        path: "Sources/OverlandHelperShared"
    ),
    // Root launchd daemon registered with SMAppService; runs gpclient.
    .executableTarget(
        name: "OverlandHelper",
        dependencies: ["OverlandCore", "OverlandHelperShared"],
        path: "Sources/OverlandHelper"
    ),
    .executableTarget(
        name: "Overland",
        dependencies: [
            "OverlandCore",
            "OverlandHelperShared",
            .product(name: "Sparkle", package: "Sparkle")
        ],
        path: "Sources/Overland",
        resources: [
            .process("Resources")
        ],
        swiftSettings: [
            .enableExperimentalFeature("IsolatedDeinit")
        ],
        linkerSettings: [
            // Sparkle.framework is embedded in Contents/Frameworks by Scripts/bundle.sh
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]
    ),
    .testTarget(
        name: "OverlandTests",
        dependencies: ["Overland", "OverlandCore", "OverlandHelperShared"],
        path: "Tests/OverlandTests"
    )
]
products.append(.executable(name: "Overland", targets: ["Overland"]))
products.append(.executable(name: "OverlandHelper", targets: ["OverlandHelper"]))
#endif

let package = Package(
    name: "Overland",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
