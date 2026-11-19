// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentRuntime",
    platforms: [.iOS(.v26), .watchOS(.v26), .macOS(.v15)],
    products: [.library(name: "AgentRuntime", targets: ["AgentRuntime"])],
    targets: [
        .target(name: "AgentRuntime", resources: [.copy("Resources/model-manifest.json")]),
        .testTarget(name: "AgentRuntimeTests", dependencies: ["AgentRuntime"])
    ]
)
