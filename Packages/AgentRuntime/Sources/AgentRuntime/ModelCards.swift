import Foundation

/// What the Model Center shows for one model. Advertised capabilities (from the developer) are kept apart from what iTalk
/// actually implements and has verified, and every performance number names where it was measured.
public struct ModelCard: Sendable, Identifiable, Equatable {
    public enum Capability: String, Sendable, CaseIterable { case text, vision, tools, reasoning, longContext, multilingual }
    public enum Status: Sendable, Equatable {
        /// Implemented in iTalk and checked with real inference (note says where / how).
        case verified(String)
        /// Implemented, not yet measured on the target device.
        case implementedUnverified(String)
        /// Advertised by the developer but not wired in iTalk.
        case notImplemented(String)
    }
    public struct Measurement: Sendable, Equatable { public var label: String; public var value: String; public var context: String }

    public var id: String
    public var name: String
    public var developer: String
    /// Asset-catalog name for the developer's logo (Codex supplies the official artwork).
    public var logoAsset: String
    public var parameters: String
    public var quantization: String
    public var advertisedContext: String
    public var iTalkContextTokens: Int
    public var downloadBytes: Int64
    public var memoryBytes: Int64
    public var license: String
    public var runsOn: String
    public var advertised: Set<Capability>
    public var inITalk: [Capability: Status]
    public var performance: [Measurement]
    public var notes: [String]
}

public enum ModelCenterCatalog {
    public static func cards() -> [ModelCard] {
        let small = ModelCatalog.qwen35_0_8b_4bit, large = ModelCatalog.qwen35_2b_4bit
        return [
            ModelCard(id: large.id, name: "Qwen3.5 2B", developer: "阿里巴巴通义千问（Qwen）", logoAsset: "logo.qwen", parameters: "20 亿",
                      quantization: "4-bit（MLX）", advertisedContext: "26.2 万 tokens", iTalkContextTokens: large.contextTokens,
                      downloadBytes: large.totalBytes, memoryBytes: large.residentBytes, license: "Apache-2.0", runsOn: "iPhone 设备端（GPU，离线）",
                      advertised: [.text, .vision, .tools, .reasoning, .longContext, .multilingual],
                      inITalk: [.text: .verified("iPhone 16 Pro Max 真机对话与语音"), .tools: .implementedUnverified("Mac 测试：可提出有效工具调用；真机工具成功率待测"),
                                .vision: .implementedUnverified("Mac 实测可识别图片；iPhone 待测"), .reasoning: .notImplemented("思考模式已关闭以降低延迟"),
                                .longContext: .notImplemented("为内存安全，iTalk 使用 4096 tokens 上下文与摘要"), .multilingual: .verified("中文为主，Mac 实测英文可用")],
                      performance: [.init(label: "首字延迟", value: "1.1–3.5 秒", context: "iPhone 16 Pro Max 语音对话实测（含工具说明的完整提示），2026-10-26"),
                                    .init(label: "生成速度", value: "26–60 tokens/秒", context: "Mac（Apple 芯片）Release 实测，非手机数据"),
                                    .init(label: "载入时间", value: "4.9 秒", context: "Mac 冷启动实测"),
                                    .init(label: "内存占用", value: "约 2.1–2.5 GB", context: "iPhone 16 Pro Max 整个 App 实测（含语音模型）")],
                      notes: ["推荐 8 GB 内存的 iPhone 使用", "小模型调用工具可能不稳定：iTalk 会校验参数、自动加载技能并重试，危险操作始终需要你确认"]),
            ModelCard(id: small.id, name: "Qwen3.5 0.8B", developer: "阿里巴巴通义千问（Qwen）", logoAsset: "logo.qwen", parameters: "8 亿",
                      quantization: "4-bit（MLX）", advertisedContext: "26.2 万 tokens", iTalkContextTokens: small.contextTokens,
                      downloadBytes: small.totalBytes, memoryBytes: small.residentBytes, license: "Apache-2.0", runsOn: "iPhone 设备端（GPU，离线）",
                      advertised: [.text, .vision, .tools, .reasoning, .longContext, .multilingual],
                      inITalk: [.text: .verified("Mac 与 iPhone 真机对话"), .tools: .implementedUnverified("与其他模型共享全部技能；Mac 测试 0/5 次主动提出工具调用，可靠性低"),
                                .vision: .implementedUnverified("Mac 实测可识别图片；iPhone 待测"), .reasoning: .notImplemented("思考模式已关闭"),
                                .longContext: .notImplemented("iTalk 使用 4096 tokens 上下文"), .multilingual: .verified("中文为主")],
                      performance: [.init(label: "生成速度", value: "53–80 tokens/秒", context: "Mac（Apple 芯片）Release 实测，非手机数据"),
                                    .init(label: "载入时间", value: "2.5 秒", context: "Mac 冷启动实测")],
                      notes: ["适合内存较小的 iPhone", "能使用所有技能，但复杂任务的成功率明显低于 2B 或云端模型"]),
            ModelCard(id: "italk-cloud", name: "iTalk 云端模型", developer: "由 iTalk 服务配置", logoAsset: "logo.italk", parameters: "—",
                      quantization: "—", advertisedContext: "取决于服务端配置", iTalkContextTokens: 128_000, downloadBytes: 0, memoryBytes: 0,
                      license: "按用量计费", runsOn: "云端（需联网、需同意云端处理）",
                      advertised: [.text, .tools, .reasoning, .longContext, .multilingual],
                      inITalk: [.text: .implementedUnverified("与本地模型共用同一个 Agent、技能与工具；需配置网关后验证"),
                                .tools: .implementedUnverified("服务端只转发工具调用，工具始终在 iPhone 上执行"),
                                .vision: .notImplemented("取决于服务端是否开启图片"), .reasoning: .notImplemented("取决于服务端模型"),
                                .longContext: .implementedUnverified("上下文预算 128K"), .multilingual: .implementedUnverified("取决于服务端模型")],
                      performance: [],
                      notes: ["个人数据（日历、联系人、位置、照片等）默认不提供给云端模型，可在 隐私与权限 中单独允许", "健康数据需单独允许"]),
        ]
    }
}
