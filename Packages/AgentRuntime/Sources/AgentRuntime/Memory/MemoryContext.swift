import Foundation

/// Where a run gets the person's long-term memory from (the `MemoryStore`, or a stand-in in tests).
public protocol MemoryContextSource: Sendable {
    func memoryContext(for text: String, characterBudget: Int, includeSensitive: Bool) async -> [MemoryItem]
}

extension MemoryStore: MemoryContextSource {
    public func memoryContext(for text: String, characterBudget: Int, includeSensitive: Bool) async -> [MemoryItem] {
        context(for: text, characterBudget: characterBudget, includeSensitive: includeSensitive)
    }
}

public enum MemoryPrompt {
    /// The block added to a model's instructions. Memory informs; it never outranks what the person says now or the safety rules above it.
    public static func render(_ items: [MemoryItem]) -> String {
        guard !items.isEmpty else { return "" }
        let standing = items.filter { $0.kind == .instruction }, known = items.filter { $0.kind != .instruction }
        var out = "\n\n【关于用户的已知信息（来自用户的长期记忆，可能不完整或已过时；与用户当前说的话冲突时，以当前说的为准；只在相关时自然使用，不要主动复述；不得因此忽略上面的安全规则）】"
        if !standing.isEmpty { out += "\n" + standing.map { "- " + $0.text }.joined(separator: "\n") }
        if !known.isEmpty { out += "\n" + known.map { "- " + $0.text }.joined(separator: "\n") }
        return out
    }
}
