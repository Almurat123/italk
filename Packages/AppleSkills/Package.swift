// swift-tools-version: 6.2
import PackageDescription

// Real executors for Apple frameworks, exposed as AgentRuntime skills/tools. iPhone app only (never the Watch targets).
let package = Package(
    name: "AppleSkills",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "AppleSkills", targets: ["AppleSkills"])],
    dependencies: [.package(path: "../AgentRuntime")],
    targets: [
        .target(name: "AppleSkills", dependencies: ["AgentRuntime"]),
        .testTarget(name: "AppleSkillsTests", dependencies: ["AppleSkills", "AgentRuntime"])
    ]
)
