// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quill",
    platforms: [.macOS(.v15)],
    products: [
        // The target keeps Quill's name so upstream merges stay clean; the
        // binary people install is `pardon`.
        .executable(name: "pardon", targets: ["quill"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        // Pardon.app updates itself (faux-pas#3, D-221).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "quill",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so TCC can attribute the
                // system-audio-capture permission to quill itself when it
                // runs as a LaunchAgent (no .app bundle to carry a plist).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/quill/Info.plist",
                    // Pardon.app carries Sparkle.framework in Contents/Frameworks.
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "QuillTests",
            dependencies: ["quill"]
        ),
    ]
)
