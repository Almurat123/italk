import Foundation

// CONTEXT MEMORY
// Updated: 2026-10-31
// Status: mixed (Mac tokenizer measurements verified; original device failure not traced)
// Why: A short request failed with "context too large" on the owner's iPhone. Mac measurements show several plausible contributors: long skill
//      instructions, a 2,048-token thinking reservation within a 4,096-token window, and inaccurate character-based estimates. The original device
//      prompt was not captured, so those measurements do not establish the exact cause of that particular failure.
// Debug Goal: Every model request is sized with the model's own tokenizer when it has one, the output reservation never starves the prompt, optional prompt
//      parts shrink in a fixed order before anything the person said is touched, and each decision is recorded as numbers (no text).
// Search Tags: context window budget reservation thinking skill brief compaction token count exact estimator report
// Invariants:
// - The person's current request, tool call/result pairs and facts the person stated are never dropped silently; compaction goes through summaries.
// - A report contains only numbers and short decision names, never conversation content.
// - The runtime window is a policy number (what we allocate and test), never the model's advertised maximum.
// Failure Modes:
// - A provider without an exact counter makes the estimate the only guard: it is deliberately conservative (see TokenEstimator).

/// What one model request looked like, in numbers only. Written for every request the runner makes, kept with the run, logged, and written by the
/// device probe, so a failure on a phone can be explained without reading the conversation.
public struct ContextReport: Codable, Sendable, Equatable {
    /// "selection" (which skills does this need) or "step" (a model step that answers or calls tools).
    public var kind: String
    public var step: Int
    /// The window the budget was computed against (what this device allocates and was tested with).
    public var window: Int
    /// What the model supports on paper, when known. Never assumed usable.
    public var advertisedWindow: Int?
    /// Prompt size of the request that was (or would have been) sent.
    public var promptTokens: Int
    /// True when `promptTokens` comes from the model's own tokenizer and chat template.
    public var exact: Bool
    public var reservedOutput: Int
    public var thinking: Bool
    /// Estimated proportions of the prompt, even when `exact` is true. Only `promptTokens` is counted using the model's tokenizer.
    public var systemTokens: Int
    public var skillTokens: Int
    public var memoryTokens: Int
    public var toolSchemaTokens: Int
    public var historyTokens: Int
    public var runTokens: Int
    /// Recovery steps applied before this request was accepted, in order (short names only).
    public var attempts: [String]
    /// "ok", or "too_large" when the request could not be made to fit.
    public var outcome: String
    public var millis: Double

    public var headroom: Int { window - promptTokens - reservedOutput }
}

/// Room for the answer. A request is accepted when the prompt leaves at least the minimum a useful answer needs; the step is then allowed to generate as
/// much as it asked for, limited by what the window really has left. (The previous rule reserved the full 2,048 thinking tokens up front, half of a
/// 4,096-token window, before looking at the prompt at all.)
public enum OutputReservation {
    /// Least room a step must keep for its answer (thinking needs more than a plain reply); below this the prompt has to shrink.
    public static func minimum(thinking: Bool, window: Int) -> Int { thinking ? min(768, max(256, window / 5)) : min(256, max(96, window / 8)) }
    /// What the step may generate: what it asked for, limited by what is left of the window after the prompt and a safety margin.
    public static func allowance(window: Int, prompt: Int, desired: Int, margin: Int) -> Int { max(0, min(desired, window - prompt - margin)) }
}

/// How much of the window the instructions of loaded skills may take in the system prompt (all loaded skills together). Longer instructions are replaced
/// by the skill's short form, or an excerpt, and the model reads the rest with `read_skill` only if it needs it. It grows with the window: a 4,096-token
/// window gives 819 tokens, 8,192 gives 1,638, and a large cloud window gives up to 4,000.
public enum SkillBudget {
    public static func promptTokens(window: Int) -> Int { max(300, min(4000, window / 5)) }
}

public extension Skill {
    /// The text that goes into the system prompt when this skill is loaded, within `tokens`. Full instructions when they fit; otherwise the
    /// short form; otherwise an excerpt cut at a line boundary with a pointer to `read_skill`. Returns whether it was shortened.
    func promptText(tokens budget: Int) -> (text: String, shortened: Bool) {
        if TokenEstimator.tokens(instructions) <= budget { return (instructions, false) }
        if let brief, !brief.isEmpty { return (brief + "\n（以上是简要说明；需要完整说明时调用 read_skill 查看 \(id)。）", true) }
        var kept = ""
        for line in instructions.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = kept.isEmpty ? String(line) : kept + "\n" + line
            if TokenEstimator.tokens(next) > budget { break }
            kept = next
        }
        return (kept + "\n…（说明较长，这里只给出开头；完整说明用 read_skill 查看 \(id)。）", true)
    }

    /// The smallest text this skill can be given in a prompt: its short form, or a 200-token excerpt.
    func briefText() -> String {
        if let brief, !brief.isEmpty { return brief + "\n（以上是简要说明；需要完整说明时调用 read_skill 查看 \(id)。）" }
        return promptText(tokens: 200).text
    }
}
