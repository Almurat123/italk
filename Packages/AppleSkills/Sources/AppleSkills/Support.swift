import Foundation
import AgentRuntime
import CryptoKit

/// UI the system requires for some capabilities (composer sheets, camera, document picker, URL opening).
/// Implemented by the app on the main actor; the tool only ever learns the outcome, never sees the screen.
public protocol SystemPresenter: Sendable {
    @MainActor func open(_ url: URL) async -> Bool
    @MainActor func canOpen(_ url: URL) -> Bool
    /// Returns "sent", "cancelled", "failed" or "unavailable". The person always taps Send themselves.
    @MainActor func composeMessage(recipients: [String], body: String) async -> String
    @MainActor func composeMail(to: [String], subject: String, body: String) async -> String
    /// Camera capture; the JPEG is written into the app container. nil = cancelled / unavailable.
    @MainActor func capturePhoto() async -> URL?
    /// Document picker (copy into the app container). nil = cancelled.
    @MainActor func pickDocument() async -> URL?
    /// Share sheet for a file the app owns. true = shared.
    @MainActor func share(_ file: URL) async -> Bool
    @MainActor func setScreenBrightness(_ value: Double) -> Bool
    @MainActor func screenBrightness() -> Double?
}

/// Everything Apple skills need from the host app.
public struct AppleSkillContext: Sendable {
    public var presenter: any SystemPresenter
    /// Folder the person's iTalk files live in (Files app visible). Tools never read outside it.
    public var filesRoot: URL
    /// Conversation image attachments (resolved by id) for Vision.
    public var attachmentURL: @Sendable (UUID) async -> URL?
    /// iTalk Spotlight index of conversations (title/snippet search).
    public var searchConversations: @Sendable (String) async -> [(id: UUID, title: String, snippet: String)]
    public init(presenter: any SystemPresenter, filesRoot: URL, attachmentURL: @escaping @Sendable (UUID) async -> URL? = { _ in nil },
                searchConversations: @escaping @Sendable (String) async -> [(id: UUID, title: String, snippet: String)] = { _ in [] }) {
        self.presenter = presenter; self.filesRoot = filesRoot; self.attachmentURL = attachmentURL; self.searchConversations = searchConversations
    }
}

// MARK: - Argument helpers

extension JSONValue {
    func str(_ k: String) -> String? { self[k]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
    func num(_ k: String) -> Double? { self[k]?.number }
    func int(_ k: String) -> Int? { self[k]?.number.map { Int($0) } }
    func flag(_ k: String) -> Bool? { self[k]?.bool }
    func strings(_ k: String) -> [String] { self[k]?.array?.compactMap(\.string) ?? (self[k]?.string.map { [$0] } ?? []) }
}

public enum ArgDate {
    /// ISO-8601 with or without zone/seconds, "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "HH:mm" (today, or tomorrow if past).
    public static func parse(_ s: String?, now: Date = .now, tz: TimeZone = .current) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = opts; if let d = iso.date(from: s) { return d }
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            f.dateFormat = fmt; if let d = f.date(from: s) { return d }
        }
        f.dateFormat = "HH:mm"
        if let t = f.date(from: s) {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
            let hm = cal.dateComponents([.hour, .minute], from: t)
            guard var d = cal.date(bySettingHour: hm.hour!, minute: hm.minute!, second: 0, of: now) else { return nil }
            if d <= now { d = cal.date(byAdding: .day, value: 1, to: d)! }
            return d
        }
        return nil
    }
    public static func iso(_ d: Date, tz: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = tz; f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }
    public static func spoken(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEEE HH:mm"; return f.string(from: d)
    }
}

func fail(_ m: String, retry: Bool = false) -> ToolFailure { ToolFailure(m, retryable: retry) }

/// A tool built from a spec and a closure — keeps each executor next to its schema.
struct FnTool: AgentTool {
    let spec: ToolSpec
    let run: @Sendable (JSONValue, ToolContext) async throws -> ToolOutput
    let describeFn: (@Sendable (JSONValue) -> String)?
    let reconcileFn: (@Sendable (String) async -> ToolOutput?)?
    init(_ spec: ToolSpec, describe: (@Sendable (JSONValue) -> String)? = nil, reconcile: (@Sendable (String) async -> ToolOutput?)? = nil,
         _ run: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolOutput) {
        self.spec = spec; self.run = run; self.describeFn = describe; self.reconcileFn = reconcile
    }
    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput { try await run(arguments, context) }
    func describe(_ arguments: JSONValue) -> String { describeFn?(arguments) ?? "\(spec.description)：\(arguments.compactString)" }
    func reconcile(idempotencyKey: String) async -> ToolOutput? { await reconcileFn?(idempotencyKey) }
}

/// Idempotency for system stores without our own key field: remembers key → created object id.
actor IdempotencyMap {
    static let shared = IdempotencyMap()
    private let defaults = UserDefaults.standard
    private let prefix = "italk.idem."
    func get(_ key: String) -> String? { defaults.string(forKey: prefix + key) }
    func set(_ key: String, _ id: String) { defaults.set(id, forKey: prefix + key) }
}

func out(_ value: [String: JSONValue], _ summary: String, id: String? = nil) -> ToolOutput {
    ToolOutput(value: .object(value), summary: summary, externalId: id)
}

/// Same idempotency key → same UUID (system objects keyed by UUID can be found again after a crash or retry).
func stableUUID(_ key: String) -> UUID {
    var b = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
    b[6] = (b[6] & 0x0F) | 0x50; b[8] = (b[8] & 0x3F) | 0x80
    return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
}
