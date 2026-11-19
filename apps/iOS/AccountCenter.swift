import Foundation
import Observation
import StoreKit
import AgentRuntime
import RemoteAgent

struct CloudServiceError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    static let notDeployed = CloudServiceError(message: "iTalk 云端服务尚未开通，暂时无法登录或订阅。设备端功能不受影响。")
}

/// Where the gateway lives. Production builds carry the URL in Info.plist (`ITalkCloudEndpoint`, set when the project is generated);
/// nobody types a hostname. Debug builds also accept an override for a developer's tunnel.
enum CloudEndpoint {
    static var url: URL? {
        #if DEBUG
        if let o = UserDefaults.standard.string(forKey: "italk.cloud.endpoint.override"), let u = URL(string: o), u.host != nil { return u }
        if let e = ProcessInfo.processInfo.environment["ITALK_CLOUD_ENDPOINT"], let u = URL(string: e), u.host != nil { return u }
        #endif
        guard let s = Bundle.main.object(forInfoDictionaryKey: "ITalkCloudEndpoint") as? String, !s.isEmpty, let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }
}

/// What the gateway says it can do right now (`GET /v2/capabilities`). The UI shows a feature only when the service reports it.
struct CloudCapabilities: Equatable {
    var passwordReset = false, emailVerification = false, signInWithApple = false, subscriptions = false
    var environment = "production"
}

/// Everything the UI shows about the paid cloud service, driven by the gateway. Local features never need an account.
/// Entitlements and quotas are read from the gateway, which verifies purchases with Apple; nothing here is a local balance.
@MainActor @Observable final class AccountCenter {
    private(set) var availability: CloudAvailability = .notDeployed
    private(set) var profile: AccountProfile?
    private(set) var plans: [SubscriptionPlan] = []
    private(set) var entitlement = Entitlement()
    private(set) var windows: [UsageWindow] = []
    private(set) var recentUsage: [UsageRecord] = []
    private(set) var cloudModels: [CloudModelInfo] = []
    private(set) var capabilities = CloudCapabilities()
    private(set) var avatarData: Data?
    /// A development gateway answered (not the production service).
    private(set) var isDeveloperGateway = false
    private(set) var isRefreshing = false
    private(set) var purchaseBlockedReason: String? = "订阅服务尚未开通。"
    private(set) var emailVerified = false
    private(set) var signInMethods: [String] = []

    private static let tokenAccount = "cloud-session"
    @ObservationIgnored private let sessionToken = TokenBox()
    @ObservationIgnored private var developerPinnedSession: PinnedSession?
    @ObservationIgnored private(set) var client: CloudClient?
    @ObservationIgnored private weak var local: LocalModelCenter?
    @ObservationIgnored private let purchases = PurchaseService()
    @ObservationIgnored private var products: [String: Product] = [:]
    @ObservationIgnored private var appleAccountToken: UUID?

    init() {
        #if DEBUG
        // CONTEXT MEMORY
        // Updated: 2026-11-01
        // Status: inferred
        // Why: A developer can explicitly provision a LAN gateway using a certificate pin over the paired device connection.
        // Debug Goal: Keep the endpoint and its exact certificate together across app launches.
        // Search Tags: developer cloud local network certificate pin provisioning
        // Invariants:
        // - Only a private IPv4 HTTPS endpoint with a SHA-256 pin is accepted here.
        // - This path is unavailable in Release and never disables certificate checking globally.
        // Failure Modes:
        // - A stale pin or changed certificate must fail closed.
        // - A session for another endpoint must not be sent to the new endpoint.
        let env = ProcessInfo.processInfo.environment
        var switchedDeveloperEndpoint = false
        if let endpoint = env["ITALK_DEV_CLOUD_ENDPOINT"], let url = URL(string: endpoint), url.scheme == "https",
           let host = url.host, Self.isPrivateIPv4(host), let pin = env["ITALK_DEV_CLOUD_CERT_PIN"], pin.count == 43 {
            switchedDeveloperEndpoint = UserDefaults.standard.string(forKey: "italk.cloud.endpoint.override") != endpoint
            UserDefaults.standard.set(endpoint, forKey: "italk.cloud.endpoint.override")
            UserDefaults.standard.set(pin, forKey: "italk.cloud.dev.certificate-pin")
        }
        #endif
        if let data = KeychainStore.read(Self.tokenAccount), let token = String(data: data, encoding: .utf8) { sessionToken.value = token }
        #if DEBUG
        if switchedDeveloperEndpoint { sessionToken.value = nil }
        #endif
        if let url = CloudEndpoint.url {
            #if DEBUG
            if url.scheme == "https", let host = url.host, Self.isPrivateIPv4(host),
               let pin = UserDefaults.standard.string(forKey: "italk.cloud.dev.certificate-pin") {
                let pinned = PinnedSession(pin: pin); developerPinnedSession = pinned
                client = CloudClient(baseURL: url, token: { [sessionToken] in sessionToken.value }, sessionOverride: pinned.session)
            } else {
                client = CloudClient(baseURL: url, token: { [sessionToken] in sessionToken.value })
            }
            #else
            client = CloudClient(baseURL: url, token: { [sessionToken] in sessionToken.value })
            #endif
        }
    }

    #if DEBUG
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }

    func provisionDeveloperSession(_ token: String) async throws {
        guard developerPinnedSession != nil, capabilities.environment == "development", !isSignedIn, token.count >= 20 else { return }
        try KeychainStore.write(Data(token.utf8), account: Self.tokenAccount, afterFirstUnlock: true)
        sessionToken.value = token
        await refresh()
        guard isSignedIn else { throw CloudServiceError(message: "开发者账户连接失败，请检查局域网连接。") }
    }
    #endif

    func bind(model: AppModel? = nil, local: LocalModelCenter) {
        self.local = local
        local.cloudClient = { [weak self] in self?.cloudClient }
        purchases.listen { [weak self] jws in await self?.submit(signedTransactions: [jws]) ?? false }
    }

    /// Model access for one of the person's own computers: a credential for this account that can run model tasks under its subscription and quota,
    /// and nothing else. It is handed to the computer over the paired, pinned channel and appears in the account's session list so it can be revoked.
    struct ComputerAccess: Sendable { var gateway: String; var token: String; var expiresAt: Date?; var name: String; var accountHint: String? }

    func createComputerAccess(name: String) async throws -> ComputerAccess {
        guard let client, let base = CloudEndpoint.url else { throw CloudServiceError.notDeployed }
        guard isSignedIn else { throw CloudServiceError(message: "请先登录 iTalk 账号，再让电脑使用 iTalk 模型。") }
        let body = try await client.json("POST", "v2/agent-sessions", body: .object(["name": .string(String(name.prefix(60)))])).body
        guard let session = body["session"], let token = session["token"]?.string else { throw CloudServiceError(message: "云端没有返回凭证，请稍后再试。") }
        return ComputerAccess(gateway: base.absoluteString, token: token, expiresAt: session["expiresAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) },
                              name: session["name"]?.string ?? name, accountHint: Self.mask(profile?.email))
    }
    private static func mask(_ email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@"), at != email.startIndex else { return nil }
        return "\(email[email.startIndex])***\(email[at...])"
    }

    var isSignedIn: Bool { profile != nil }
    var canUseCloudModels: Bool { availability == .available }
    /// The client the agent uses for cloud model steps; nil unless the person is signed in with an active subscription.
    var cloudClient: CloudClient? { availability == .available ? client : nil }

    // MARK: Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true; defer { isRefreshing = false }
        guard let client else { reset(.notDeployed); return }
        do {
            let caps = try await client.json("GET", "v2/capabilities", authorized: false).body
            capabilities = CloudCapabilities(passwordReset: caps["passwordReset"]?.bool ?? false, emailVerification: caps["emailVerification"]?.bool ?? false,
                                             signInWithApple: caps["signInWithApple"]?.bool ?? false, subscriptions: caps["subscriptions"]?.bool ?? false,
                                             environment: caps["environment"]?.string ?? "production")
            isDeveloperGateway = capabilities.environment != "production"
            async let planBody = client.json("GET", "v2/plans", authorized: false).body
            async let modelBody = client.json("GET", "v2/models", authorized: false).body
            let serverPlans = try await planBody["plans"]?.array ?? [], serverModels = try await modelBody["models"]?.array ?? []
            await loadProducts(ids: serverPlans.compactMap { $0["productId"]?.string })
            guard !(sessionToken.value ?? "").isEmpty else {
                apply(plans: serverPlans, models: serverModels, subscribedModels: [])
                profile = nil; entitlement = Entitlement(); windows = []; availability = .needsSignIn; return
            }
            let account = try await client.json("GET", "v2/account").body
            applyAccount(account)
            apply(plans: serverPlans, models: serverModels, subscribedModels: Set(account["models"]?.array?.compactMap(\.string) ?? []))
            if let usage = try? await client.json("GET", "v2/usage", query: [URLQueryItem(name: "limit", value: "30")]).body["records"]?.array {
                recentUsage = usage.compactMap { r in
                    guard let id = r["id"]?.string, let model = r["model"]?.string else { return nil }
                    return UsageRecord(id: id, date: Date(timeIntervalSince1970: (r["date"]?.number ?? 0) / 1000), modelId: model, kind: "chat", points: r["points"]?.number ?? 0,
                                       inputTokens: r["inputTokens"]?.number.map(Int.init), outputTokens: r["outputTokens"]?.number.map(Int.init))
                }
            }
            await refreshAvatar()
            availability = entitlement.status == .active || entitlement.status == .gracePeriod ? .available : .needsSubscription
        } catch let e as CloudAPIError where e.status == 401 {
            clearSession(); availability = .needsSignIn
        } catch let e as CloudAPIError {
            availability = e.isNetwork ? .offline : .serviceError(e.errorDescription ?? e.code)
        } catch { availability = .serviceError(error.localizedDescription) }
        pushModelsToLocal()
    }

    private func reset(_ next: CloudAvailability) {
        availability = next; profile = nil; plans = []; entitlement = Entitlement(); windows = []; recentUsage = []; cloudModels = []; avatarData = nil
        purchaseBlockedReason = "订阅服务尚未开通。"; pushModelsToLocal()
    }

    private func clearSession() {
        sessionToken.value = nil; KeychainStore.delete(Self.tokenAccount)
        profile = nil; entitlement = Entitlement(); windows = []; recentUsage = []; avatarData = nil; appleAccountToken = nil
    }

    private func applyAccount(_ body: JSONValue) {
        if let a = body["account"], let id = a["id"]?.string {
            profile = AccountProfile(id: id, displayName: a["displayName"]?.string, email: a["email"]?.string,
                                     method: (a["signInMethods"]?.array?.first?.string == "apple") ? .apple : .email,
                                     createdAt: Date(timeIntervalSince1970: (a["createdAt"]?.number ?? 0) / 1000))
            emailVerified = a["emailVerified"]?.bool ?? false
            signInMethods = a["signInMethods"]?.array?.compactMap(\.string) ?? []
            appleAccountToken = a["appleAccountToken"]?.string.flatMap(UUID.init(uuidString:))
        }
        if let s = body["subscription"] {
            let status = EntitlementStatus(rawValue: Self.statusName(s["status"]?.string)) ?? .none
            let end = s["periodEnd"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
            let autoRenew = s["autoRenew"]?.bool ?? true
            entitlement = Entitlement(planId: s["planId"]?.string, tier: s["tier"]?.string, status: status,
                                      periodStart: s["periodStart"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }, periodEnd: end,
                                      renewsAt: autoRenew ? end : nil, cancelsAtPeriodEnd: !autoRenew && status == .active)
            windows = [("weekly", UsageWindow.Kind.weekly, "本周用量"), ("period", .period, "本订阅周期用量")].compactMap { key, kind, title in
                guard let w = s["windows"]?[key], let limit = w["limit"]?.number, let used = w["used"]?.number, let reset = w["resetsAt"]?.number else { return nil }
                return UsageWindow(kind: kind, title: title, used: used, limit: limit, resetsAt: Date(timeIntervalSince1970: reset / 1000))
            }
        }
    }

    private static func statusName(_ s: String?) -> String {
        switch s { case "grace": "gracePeriod"; case "billing_retry": "billingRetry"; case let x?: x; default: "none" }
    }

    private func apply(plans serverPlans: [JSONValue], models serverModels: [JSONValue], subscribedModels: Set<String>) {
        plans = serverPlans.compactMap { p in
            guard let id = p["productId"]?.string, let name = p["name"]?.string else { return nil }
            let weekly = Int(p["weeklyPoints"]?.number ?? 0), period = Int(p["periodPoints"]?.number ?? 0)
            return SubscriptionPlan(id: id, tier: p["tier"]?.string ?? "plus", name: name, period: p["period"]?.string == "annual" ? .annual : .monthly,
                                    priceText: products[id]?.displayPrice ?? "—", includedSummary: "每周 \(weekly) 点，整个订阅周期 \(period) 点")
        }
        cloudModels = serverModels.compactMap { m in
            guard let id = m["id"]?.string, let name = m["name"]?.string else { return nil }
            let allowed = subscribedModels.contains(id)
            return CloudModelInfo(id: id, name: name, developer: m["developer"]?.string ?? "", summary: m["note"]?.string ?? "", supportsImages: m["supportsImages"]?.bool ?? false,
                                  supportsTools: m["supportsTools"]?.bool ?? true, supportsReasoning: m["supportsReasoning"]?.bool ?? false, usageWeight: m["usageWeight"]?.number,
                                  available: allowed && (m["available"]?.bool ?? true), unavailableReason: allowed ? nil : (isSignedIn ? "需要订阅" : "需要登录并订阅"))
        }
        if !capabilities.subscriptions { purchaseBlockedReason = "订阅服务尚未开通。" }
        else if !isSignedIn { purchaseBlockedReason = "请先登录。" }
        else if products.isEmpty { purchaseBlockedReason = "暂时无法从 App Store 读取订阅价格。" }
        else { purchaseBlockedReason = nil }
    }

    private func pushModelsToLocal() {
        local?.setManagedCloudModels(cloudModels.map { GatewayCloudModel(id: $0.id, name: $0.name, available: $0.available, supportsImages: $0.supportsImages, note: $0.unavailableReason ?? $0.summary) })
    }

    private func loadProducts(ids: [String]) async { products = await purchases.products(for: ids) }

    // MARK: Sign in, profile

    private func require() throws -> CloudClient {
        guard let client else { throw CloudServiceError.notDeployed }
        return client
    }

    private func adopt(_ body: JSONValue) throws {
        guard let token = body["session"]?["token"]?.string else { throw CloudAPIError(code: "gateway_bad_response", status: 200) }
        sessionToken.value = token
        try? KeychainStore.write(Data(token.utf8), account: Self.tokenAccount, afterFirstUnlock: true)
    }

    private static var device: JSONValue { .object(["name": .string(UIDeviceName.current), "platform": .string("ios")]) }

    func signIn(email: String, password: String) async throws {
        let body = try await require().json("POST", "v2/auth/login", body: .object(["email": .string(email), "password": .string(password), "device": Self.device]), authorized: false).body
        try adopt(body); await refresh()
    }

    func signUp(email: String, password: String, displayName: String? = nil) async throws {
        var b: [String: JSONValue] = ["email": .string(email), "password": .string(password), "device": Self.device]
        if let displayName, !displayName.isEmpty { b["displayName"] = .string(displayName) }
        let body = try await require().json("POST", "v2/auth/register", body: .object(b), authorized: false).body
        try adopt(body); await refresh()
    }

    /// `identityToken` and `nonce` come from the Apple authorization (UI side); the gateway verifies them against Apple's keys.
    func signInWithApple(identityToken: String, nonce: String?, givenName: String?, familyName: String?) async throws {
        var b: [String: JSONValue] = ["identityToken": .string(identityToken), "device": Self.device]
        if let nonce { b["nonce"] = .string(nonce) }
        if givenName != nil || familyName != nil { b["fullName"] = .object(["given": .string(givenName ?? ""), "family": .string(familyName ?? "")]) }
        let body = try await require().json("POST", "v2/auth/apple", body: .object(b), authorized: false).body
        try adopt(body); await refresh()
    }

    func signOut() {
        let client = client
        Task { _ = try? await client?.json("POST", "v2/auth/logout") }
        clearSession(); availability = client == nil ? .notDeployed : .needsSignIn; cloudModels = cloudModels.map { var m = $0; m.available = false; return m }; pushModelsToLocal()
    }

    func requestPasswordReset(email: String) async throws { try await require().json("POST", "v2/auth/password-reset/request", body: .object(["email": .string(email)]), authorized: false) }
    func confirmPasswordReset(email: String, code: String, newPassword: String) async throws {
        try await require().json("POST", "v2/auth/password-reset/confirm", body: .object(["email": .string(email), "code": .string(code), "newPassword": .string(newPassword)]), authorized: false)
    }
    func requestEmailVerification() async throws { try await require().json("POST", "v2/auth/email/verify/request") }
    func confirmEmail(code: String) async throws { try await require().json("POST", "v2/auth/email/verify/confirm", body: .object(["code": .string(code)])); await refresh() }

    func updateProfile(displayName: String) async throws { applyAccount(JSONValue.object(["account": try await require().json("PATCH", "v2/account", body: .object(["displayName": .string(displayName)])).body["account"] ?? .null])) }
    func setAvatar(_ imageData: Data, contentType: String = "image/jpeg") async throws { _ = try await require().upload("v2/account/avatar", data: imageData, contentType: contentType); avatarData = imageData; await refresh() }
    func removeAvatar() async throws { try await require().json("DELETE", "v2/account/avatar"); avatarData = nil; await refresh() }
    func changePassword(current: String, new: String) async throws { try await require().json("POST", "v2/account/password", body: .object(["current": .string(current), "next": .string(new)])) }
    func deleteAccount(password: String) async throws {
        try await require().json("DELETE", "v2/account", body: .object(["password": .string(password)]))
        clearSession(); availability = .needsSignIn; pushModelsToLocal()
    }

    private func refreshAvatar() async {
        guard profile != nil, let client, let hasAvatar = Optional(true), hasAvatar else { return }
        avatarData = (try? await client.download("v2/account/avatar"))?.0
    }

    // MARK: Purchases (verified by the gateway, never by the phone)

    func purchase(_ plan: SubscriptionPlan) async throws {
        guard let product = products[plan.id], let token = appleAccountToken else { throw CloudServiceError(message: purchaseBlockedReason ?? "暂时无法购买。") }
        switch try await purchases.purchase(product, accountToken: token) {
        case .purchased(let jws, let finish):
            guard await submit(signedTransactions: [jws]) else { throw CloudServiceError(message: "购买已完成，但服务器还没有确认。稍后会自动重试，也可以点“恢复购买”。") }
            await finish()
        case .pending: throw CloudServiceError(message: "购买正在等待批准（例如“询问购买”）。批准后会自动生效。")
        case .cancelled: break
        }
    }

    func restorePurchases() async throws {
        let jws = await purchases.currentEntitlements()
        guard !jws.isEmpty else { throw CloudServiceError(message: "这个 Apple ID 下没有可恢复的订阅。") }
        guard await submit(signedTransactions: jws) else { throw CloudServiceError(message: "服务器没有确认这些订阅，请稍后再试。") }
    }

    /// Returns true when the gateway accepted (or already knew) the transactions.
    private func submit(signedTransactions: [String]) async -> Bool {
        guard let client, !(sessionToken.value ?? "").isEmpty else { return false }
        do {
            _ = try await client.json("POST", "v2/iap/transactions", body: .object(["signedTransactions": .array(signedTransactions.map(JSONValue.string))]))
            await refresh(); return true
        } catch { return false }
    }
}

/// Thread-safe holder so the HTTP client can read the current token without touching the main actor.
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock(); private var token: String?
    var value: String? { get { lock.withLock { token } } set { lock.withLock { token = newValue } } }
}

enum UIDeviceName {
    static var current: String { ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "") }
}
