// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PrimeCueRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CueCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "PrimeCueRecorder", dependencies: ["CueCore"]),
        .testTarget(name: "CueCoreTests", dependencies: ["CueCore"]),
    ]
)
