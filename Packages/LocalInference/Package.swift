// swift-tools-version: 6.2
import PackageDescription

// Local inference engine adapter. Kept out of AgentRuntime so the runtime stays dependency-free and fast to test.
// FoundationModelsIntegration is disabled on purpose: that trait needs the iOS/macOS 27 SDK types and would
// break the iOS 26 baseline.
let package = Package(
    name: "LocalInference",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "MLXProvider", targets: ["MLXProvider"])],
    dependencies: [
        .package(path: "../AgentRuntime"),
        .package(path: "../AppleSkills"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(name: "MLXProvider", dependencies: [
            .product(name: "AgentRuntime", package: "AgentRuntime"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .testTarget(name: "MLXProviderTests", dependencies: ["MLXProvider", .product(name: "AppleSkills", package: "AppleSkills")]),
    ]
)
