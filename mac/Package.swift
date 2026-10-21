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
        .library(name: "CombustionMacPlatform", targets: ["CombustionMacPlatform"]),
        .executable(name: "colby-sim", targets: ["ColbySim"]),
        .executable(name: "colby-capture", targets: ["ColbyCapture"]),
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
        // macOS notification, sound and keep-awake adapters. Compiles to an empty module off Apple platforms.
        .target(name: "CombustionMacPlatform", dependencies: ["CombustionCore"]),
        // Debug CLI: CombustionApp against simulated probes, with a live table.
        .executableTarget(name: "ColbySim", dependencies: ["CombustionCore", "CombustionSim"]),
        // Info.plist is embedded in the binary so CoreBluetooth finds NSBluetoothAlwaysUsageDescription.
        .executableTarget(
            name: "ColbyCapture",
            dependencies: ["CombustionCore", "CombustionSim", "CombustionCoreBluetooth"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(
                ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                 "-Xlinker", "\(Context.packageDirectory)/Sources/ColbyCapture/Info.plist"],
                .when(platforms: [.macOS]))]),
        .testTarget(name: "CombustionCodecTests", dependencies: ["CombustionCodec"]),
        .testTarget(name: "CombustionCoreTests", dependencies: ["CombustionCore", "CombustionSim"]),
        .testTarget(name: "CombustionSimTests", dependencies: ["CombustionSim"]),
    ]
)
