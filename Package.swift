// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoatVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GoatVoiceCore", targets: ["GoatVoiceCore"]),
        .library(name: "GoatVoicePlatform", targets: ["GoatVoicePlatform"]),
        .executable(name: "GoatVoiceApp", targets: ["GoatVoiceApp"]),
        .executable(name: "GoatVoiceService", targets: ["GoatVoiceService"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6")
    ],
    targets: [
        .target(name: "GoatVoiceCore"),
        .target(name: "GoatVoicePlatform", dependencies: ["GoatVoiceCore"]),
        .executableTarget(
            name: "GoatVoiceApp",
            dependencies: ["GoatVoiceCore", "GoatVoicePlatform", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(
            name: "GoatVoiceService",
            dependencies: [
                "GoatVoiceCore", "GoatVoicePlatform",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift")
            ]
        ),
        .testTarget(name: "GoatVoiceCoreTests", dependencies: ["GoatVoiceCore"]),
        .testTarget(name: "GoatVoicePlatformTests", dependencies: ["GoatVoiceCore", "GoatVoicePlatform"]),
        .testTarget(name: "GoatVoiceServiceTests", dependencies: ["GoatVoiceService"]),
        .testTarget(name: "GoatVoiceAppTests", dependencies: ["GoatVoiceCore", "GoatVoicePlatform", "GoatVoiceApp"])
    ],
    swiftLanguageModes: [.v5]
)
