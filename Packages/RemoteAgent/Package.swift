// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RemoteAgent",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "RemoteAgent", targets: ["RemoteAgent"])],
    dependencies: [.package(path: "../AgentRuntime")],
    targets: [
        .target(name: "RemoteAgent", dependencies: [.product(name: "AgentRuntime", package: "AgentRuntime")]),
        .testTarget(name: "RemoteAgentTests", dependencies: ["RemoteAgent"])
    ]
)
