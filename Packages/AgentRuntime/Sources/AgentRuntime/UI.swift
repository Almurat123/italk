import Foundation

/// Declarative card schema. The model never emits SwiftUI or scripts; the app renders only these cases.
public struct UIComponent: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = 1
    public var schemaVersion: Int = UIComponent.schemaVersion
    public var id: String                 // stable componentId
    public var runId: UUID
    public var revision: Int
    public var content: Content
    public var actions: [UIAction]
    public var expiresAt: Date?

    public struct Option: Codable, Sendable, Equatable { public var id: String; public var label: String; public var detail: String?
        public init(id: String, label: String, detail: String? = nil) { self.id = id; self.label = label; self.detail = detail } }
    public struct SearchHit: Codable, Sendable, Equatable { public var title: String; public var url: String; public var snippet: String
        public init(title: String, url: String, snippet: String) { self.title = title; self.url = url; self.snippet = snippet } }
    public struct FormField: Codable, Sendable, Equatable { public var id: String; public var label: String; public var kind: String; public var required: Bool
        public init(id: String, label: String, kind: String, required: Bool) { self.id = id; self.label = label; self.kind = kind; self.required = required } }
    public struct Step: Codable, Sendable, Equatable { public var label: String; public var state: String
        public init(label: String, state: String) { self.label = label; self.state = state } }

    public enum Content: Codable, Sendable, Equatable {
        case information(title: String, body: String)
        case progress(title: String, fraction: Double?, detail: String)
        case toolActivity(toolName: String, status: String, summary: String)
        case searchResult(query: String, hits: [SearchHit])
        case choice(prompt: String, options: [Option])
        case confirmation(summary: String, confirmLabel: String, cancelLabel: String)
        case healthSummary(metric: String, value: String, unit: String, asOf: Date?, coverage: String, note: String)
        case dateTimePicker(prompt: String, earliest: Date?, latest: Date?)
        case form(title: String, fields: [FormField])
        case taskProgress(title: String, steps: [Step])
        case approval(toolName: String, summary: String, risk: PermissionClass)
        case followUp(suggestions: [String])
        case errorRecovery(message: String, retryable: Bool)
        /// A tool could not run because of an authorization. The app offers the recovery (open Settings / iTalk switch).
        case permissionRecovery(permission: SystemPermission, capability: Capability, message: String, recovery: PermissionRecovery)
        /// Sources a web answer is based on (rendered as tappable citations).
        case citations(sources: [SearchHit])

        public var kindName: String {
            switch self {
            case .information: "InformationCard"; case .progress: "ProgressCard"; case .toolActivity: "ToolActivityCard"
            case .searchResult: "SearchResultCard"; case .choice: "ChoiceCard"; case .confirmation: "ConfirmationCard"
            case .healthSummary: "HealthSummaryCard"; case .dateTimePicker: "DateTimePickerCard"; case .form: "FormCard"
            case .taskProgress: "TaskProgressCard"; case .approval: "ApprovalCard"; case .followUp: "FollowUpCard"
            case .errorRecovery: "ErrorRecoveryCard"; case .permissionRecovery: "PermissionRecoveryCard"; case .citations: "CitationsCard"
            }
        }
    }
    public init(id: String, runId: UUID, revision: Int = 1, content: Content, actions: [UIAction] = [], expiresAt: Date? = nil) {
        self.id = id; self.runId = runId; self.revision = revision; self.content = content; self.actions = actions; self.expiresAt = expiresAt
    }
}

public enum ActionAuthorization: Int, Codable, Sendable, Comparable {
    case none = 0, userTap = 1, deviceAuth = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct UIAction: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case select, approve, decline, submit, retry, dismiss }
    public var id: String                 // actionId
    public var kind: Kind
    public var label: String
    public var requires: ActionAuthorization
    public init(id: String, kind: Kind, label: String, requires: ActionAuthorization = .userTap) {
        self.id = id; self.kind = kind; self.label = label; self.requires = requires
    }
}

/// What SwiftUI sends back. Every field is checked by `ActionValidator`; the model cannot forge one.
public struct UIActionResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runId: UUID
    public var componentId: String
    public var componentRevision: Int
    public var actionId: String
    public var idempotencyKey: String
    public var authorization: ActionAuthorization
    public var payload: JSONValue
    public init(schemaVersion: Int = UIComponent.schemaVersion, runId: UUID, componentId: String, componentRevision: Int, actionId: String, idempotencyKey: String, authorization: ActionAuthorization = .userTap, payload: JSONValue = .null) {
        self.schemaVersion = schemaVersion; self.runId = runId; self.componentId = componentId; self.componentRevision = componentRevision
        self.actionId = actionId; self.idempotencyKey = idempotencyKey; self.authorization = authorization; self.payload = payload
    }
}

public enum ActionRejection: String, Error, Codable, Sendable {
    case unsupportedSchema, wrongRun, unknownComponent, staleRevision, componentClosed, expired
    case unknownAction, duplicate, unauthorized, invalidPayload, noPendingInteraction
}

public struct ComponentRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case open, completed, removed }
    public var component: UIComponent
    public var status: Status
}

public enum ActionValidator {
    public static func validate(_ r: UIActionResponse, runId: UUID, record: ComponentRecord?, seenKeys: Set<String>, now: Date) throws -> UIAction {
        guard r.schemaVersion == UIComponent.schemaVersion else { throw ActionRejection.unsupportedSchema }
        guard r.runId == runId else { throw ActionRejection.wrongRun }
        guard let record else { throw ActionRejection.unknownComponent }
        if seenKeys.contains(r.idempotencyKey) { throw ActionRejection.duplicate }
        guard record.status == .open else { throw ActionRejection.componentClosed }
        guard r.componentRevision == record.component.revision else { throw ActionRejection.staleRevision }
        if let exp = record.component.expiresAt, now >= exp { throw ActionRejection.expired }
        guard let action = record.component.actions.first(where: { $0.id == r.actionId }) else { throw ActionRejection.unknownAction }
        guard r.authorization >= action.requires else { throw ActionRejection.unauthorized }
        switch (record.component.content, action.kind) {
        case (.choice(_, let options), .select):
            guard let id = r.payload["optionId"]?.string, options.contains(where: { $0.id == id }) else { throw ActionRejection.invalidPayload }
        case (.choice, .dismiss), (.confirmation, .approve), (.confirmation, .decline), (.approval, .approve), (.approval, .decline), (.errorRecovery, .retry), (.errorRecovery, .dismiss): break
        case (.form(_, let fields), .submit):
            let values = r.payload.object ?? [:]
            guard fields.filter(\.required).allSatisfy({ values[$0.id] != nil && values[$0.id] != .null }),
                  values.keys.allSatisfy({ k in fields.contains { $0.id == k } }) else { throw ActionRejection.invalidPayload }
        case (.dateTimePicker(_, let lo, let hi), .submit):
            guard let s = r.payload["date"]?.string, let d = ISO8601DateFormatter().date(from: s),
                  (lo.map { d >= $0 } ?? true), (hi.map { d <= $0 } ?? true) else { throw ActionRejection.invalidPayload }
        case (.followUp(let s), .select):
            guard let t = r.payload["suggestion"]?.string, s.contains(t) else { throw ActionRejection.invalidPayload }
        default: throw ActionRejection.invalidPayload
        }
        return action
    }
}
