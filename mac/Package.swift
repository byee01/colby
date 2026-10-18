// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Colby",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CombustionCodec", targets: ["CombustionCodec"]),
        .library(name: "CombustionCore", targets: ["CombustionCore"]),
        .library(name: "CombustionSim", targets: ["CombustionSim"]),
        .library(name: "CombustionCoreBluetooth", targets: ["CombustionCoreBluetooth"]),
    ],
    targets: [
        // Pure wire codec. No dependencies, no I/O, no clock.
        .target(name: "CombustionCodec"),
        // System SQLite (SDK on macOS, libsqlite3-dev on Linux).
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        // Links, stores, presenter, alert engine, clock, transport protocols.
        .target(name: "CombustionCore", dependencies: ["CombustionCodec", "CSQLite"]),
        // SimulatedTransport, RecordingTransport, replay files.
        .target(name: "CombustionSim", dependencies: ["CombustionCore"]),
        // CoreBluetooth BleTransport. Compiles to an empty module off Apple platforms.
        .target(name: "CombustionCoreBluetooth", dependencies: ["CombustionCore"]),
        .testTarget(name: "CombustionCodecTests", dependencies: ["CombustionCodec"]),
        .testTarget(name: "CombustionCoreTests", dependencies: ["CombustionCore", "CombustionSim"]),
        .testTarget(name: "CombustionSimTests", dependencies: ["CombustionSim"]),
    ]
)
