// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PrimeCueRecorder",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .target(name: "CueCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "PrimeCueRecorder",
            dependencies: ["CueCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Contents/Frameworks by scripts/build-app.sh
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "CueCoreTests", dependencies: ["CueCore"]),
    ]
)
