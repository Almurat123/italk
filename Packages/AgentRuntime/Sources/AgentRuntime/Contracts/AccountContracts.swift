import Foundation

// MARK: - Account, subscription, usage (managed cloud only; local features never need any of this)

/// Whether the paid cloud service can be used right now. Never `.available` without a verified, signed-in account.
public enum CloudAvailability: Codable, Sendable, Equatable {
    /// The iTalk cloud service has not been deployed / configured for this build. Nothing paid can work.
    case notDeployed
    case needsSignIn
    case offline
    /// Signed in, but there is no active subscription (cloud models are locked; local features still work).
    case needsSubscription
    case available
    /// The service answered with an error the person can read.
    case serviceError(String)
}

public enum AccountSignInMethod: String, Codable, Sendable, CaseIterable { case email, apple }

public struct AccountProfile: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String?
    public var email: String?
    public var method: AccountSignInMethod
    public var createdAt: Date
    public init(id: String, displayName: String?, email: String?, method: AccountSignInMethod, createdAt: Date) {
        self.id = id; self.displayName = displayName; self.email = email; self.method = method; self.createdAt = createdAt
    }
}

public enum PlanPeriod: String, Codable, Sendable { case monthly, annual }

/// A purchasable plan (display data comes from StoreKit; the entitlement itself is verified by the server).
public struct SubscriptionPlan: Identifiable, Codable, Sendable, Equatable {
    /// App Store product id.
    public var id: String
    public var tier: String
    public var name: String
    public var period: PlanPeriod
    /// Localized price from StoreKit (never hard-coded).
    public var priceText: String
    /// Honest summary of what it includes: "每周 X 点，整个周期 Y 点".
    public var includedSummary: String
    public init(id: String, tier: String, name: String, period: PlanPeriod, priceText: String, includedSummary: String) {
        self.id = id; self.tier = tier; self.name = name; self.period = period; self.priceText = priceText; self.includedSummary = includedSummary
    }
}

public enum EntitlementStatus: String, Codable, Sendable {
    case none, active, gracePeriod, billingRetry, expired, revoked, refunded
}

public struct Entitlement: Codable, Sendable, Equatable {
    public var planId: String?
    public var tier: String?
    public var status: EntitlementStatus
    public var periodStart: Date?
    public var periodEnd: Date?
    public var renewsAt: Date?
    /// Cancelled in the App Store; stays active until `periodEnd`.
    public var cancelsAtPeriodEnd: Bool
    public init(planId: String? = nil, tier: String? = nil, status: EntitlementStatus = .none, periodStart: Date? = nil,
                periodEnd: Date? = nil, renewsAt: Date? = nil, cancelsAtPeriodEnd: Bool = false) {
        self.planId = planId; self.tier = tier; self.status = status; self.periodStart = periodStart; self.periodEnd = periodEnd
        self.renewsAt = renewsAt; self.cancelsAtPeriodEnd = cancelsAtPeriodEnd
    }
}

/// One quota window. A subscription has a weekly window and a whole-billing-period window; both are enforced server-side.
public struct UsageWindow: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case weekly, period }
    public var kind: Kind
    public var id: String { kind.rawValue }
    public var title: String
    /// Usage points (model-weighted), not tokens or money.
    public var used: Double
    public var limit: Double
    public var resetsAt: Date
    public var remaining: Double { max(0, limit - used) }
    public var fraction: Double { limit > 0 ? min(1, used / limit) : 1 }
    public init(kind: Kind, title: String, used: Double, limit: Double, resetsAt: Date) {
        self.kind = kind; self.title = title; self.used = used; self.limit = limit; self.resetsAt = resetsAt
    }
}

public struct UsageRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var date: Date
    public var modelId: String
    public var kind: String          // chat / voice
    public var points: Double
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(id: String, date: Date, modelId: String, kind: String, points: Double, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.id = id; self.date = date; self.modelId = modelId; self.kind = kind; self.points = points
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

public struct CloudModelInfo: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var developer: String
    public var summary: String
    /// Capabilities the service really offers for this model (not marketing).
    public var supportsImages: Bool
    public var supportsTools: Bool
    public var supportsReasoning: Bool
    /// How many usage points this model consumes relative to the baseline model (shown as "用量权重"). nil = the service does not publish weights yet.
    public var usageWeight: Double?
    public var available: Bool
    public var unavailableReason: String?
    public init(id: String, name: String, developer: String, summary: String, supportsImages: Bool, supportsTools: Bool,
                supportsReasoning: Bool, usageWeight: Double?, available: Bool, unavailableReason: String? = nil) {
        self.id = id; self.name = name; self.developer = developer; self.summary = summary; self.supportsImages = supportsImages
        self.supportsTools = supportsTools; self.supportsReasoning = supportsReasoning; self.usageWeight = usageWeight
        self.available = available; self.unavailableReason = unavailableReason
    }
}
