// swift-tools-version: 6.0
// PureMacKit — the UI-independent engine of PureMac (scanning, ownership, rules, cleanup, persistence).
// No third-party dependencies: only Apple system frameworks and the system SQLite3 library.
import PackageDescription

let package = Package(
    name: "PureMacKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PureMacKit", targets: ["PureMacKit"]),
    ],
    targets: [
        .target(
            name: "PureMacKit",
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "PureMacKitTests",
            dependencies: ["PureMacKit"]
        ),
    ]
)
