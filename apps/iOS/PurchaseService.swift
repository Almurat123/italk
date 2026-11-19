import Foundation
import StoreKit

/// StoreKit 2 plumbing. Prices and the purchase sheet come from the App Store; whether the person is entitled is decided only by the
/// gateway after it verifies the signed transaction (`AccountCenter` sends the JWS). Nothing here grants access by itself.
@MainActor final class PurchaseService {
    private var updates: Task<Void, Never>?

    func products(for ids: [String]) async -> [String: Product] {
        guard !ids.isEmpty, let list = try? await Product.products(for: ids) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    enum Outcome { case purchased(jws: String, finish: () async -> Void), pending, cancelled }

    /// Starts the purchase; the account's `appAccountToken` is attached so the gateway can bind the transaction to its buyer.
    func purchase(_ product: Product, accountToken: UUID) async throws -> Outcome {
        switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw AppFailure.message("App Store 未能验证这笔交易，没有扣费生效。") }
            return .purchased(jws: verification.jwsRepresentation, finish: { await transaction.finish() })
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .cancelled
        }
    }

    /// Signed transactions of every subscription the Apple ID currently holds (Restore Purchases).
    func currentEntitlements() async -> [String] {
        try? await AppStore.sync()
        var out: [String] = []
        for await result in Transaction.currentEntitlements { if case .verified = result { out.append(result.jwsRepresentation) } }
        return out
    }

    /// Renewals, refunds and purchases made on another device arrive here; each is forwarded to the gateway for verification.
    func listen(_ handler: @escaping @MainActor (String) async -> Bool) {
        updates?.cancel()
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard self != nil, case .verified(let transaction) = result else { continue }
                if await handler(result.jwsRepresentation) { await transaction.finish() }
            }
        }
    }
}
