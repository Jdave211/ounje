import Foundation
import StoreKit

struct StoreProductSnapshot: Hashable {
    let productID: String
    let displayPrice: String
    let hasIntroductoryOffer: Bool
    let isEligibleForIntroOffer: Bool
}

enum StoreBillingError: LocalizedError {
    case authenticationRequired
    case productUnavailable
    case purchaseCancelled
    case purchasePending
    case purchaseUnverified

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Sign in again to manage your membership."
        case .productUnavailable:
            return "Membership products could not be loaded right now."
        case .purchaseCancelled:
            return "Purchase cancelled."
        case .purchasePending:
            return "Purchase is pending approval."
        case .purchaseUnverified:
            return "The App Store transaction could not be verified."
        }
    }
}

final class StoreKitMembershipBillingService {
    static let shared = StoreKitMembershipBillingService()

    private init() {}

    private let productIDsByPlan: [OunjeMembershipPlan: String] = [
        .init(tier: .plus, cadence: .monthly): "net.ounje.plus.monthly",
        .init(tier: .plus, cadence: .yearly): "net.ounje.plus.annually",
    ]

    func fetchProductsByPlan() async throws -> [OunjeMembershipPlan: StoreProductSnapshot] {
        let products = try await Product.products(for: Array(productIDsByPlan.values))
        let productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        var snapshots: [OunjeMembershipPlan: StoreProductSnapshot] = [:]
        for (plan, productID) in productIDsByPlan {
            guard let product = productsByID[productID] else { continue }
            let subscription = product.subscription
            let isEligibleForIntroOffer = await subscription?.isEligibleForIntroOffer ?? false
            snapshots[plan] = StoreProductSnapshot(
                productID: product.id,
                displayPrice: product.displayPrice,
                hasIntroductoryOffer: subscription?.introductoryOffer != nil,
                isEligibleForIntroOffer: isEligibleForIntroOffer
            )
        }
        return snapshots
    }

    func fetchProductsByTier() async throws -> [OunjePricingTier: StoreProductSnapshot] {
        let productsByPlan = try await fetchProductsByPlan()
        var snapshots: [OunjePricingTier: StoreProductSnapshot] = [:]
        for (plan, snapshot) in productsByPlan {
            guard plan.cadence == .monthly || snapshots[plan.tier] == nil else { continue }
            snapshots[plan.tier] = snapshot
        }
        return snapshots
    }

    func purchase(plan: OunjeMembershipPlan, userID: String) async throws -> AppUserEntitlement {
        guard let productID = productIDsByPlan[plan] else {
            throw StoreBillingError.productUnavailable
        }
        let products = try await Product.products(for: [productID])
        guard let product = products.first else {
            throw StoreBillingError.productUnavailable
        }

        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken = UUID(uuidString: userID) {
            options.insert(.appAccountToken(appAccountToken))
        }

        let result = try await product.purchase(options: options)
        switch result {
        case .success(let verificationResult):
            let transaction = try verifiedTransaction(from: verificationResult)
            await transaction.finish()
            return entitlement(from: transaction, plan: plan, status: .active, userID: userID)
        case .pending:
            throw StoreBillingError.purchasePending
        case .userCancelled:
            throw StoreBillingError.purchaseCancelled
        @unknown default:
            throw StoreBillingError.productUnavailable
        }
    }

    func restorePurchases(userID: String) async throws -> AppUserEntitlement? {
        try await AppStore.sync()
        return try await currentEntitlementSnapshot(userID: userID)
    }

    func currentEntitlementSnapshot(userID: String? = nil) async throws -> AppUserEntitlement? {
        var resolved: AppUserEntitlement?

        for await verificationResult in StoreKit.Transaction.currentEntitlements {
            let transaction = try verifiedTransaction(from: verificationResult)
            guard let plan = plan(for: transaction.productID) else { continue }
            let candidate = entitlement(
                from: transaction,
                plan: plan,
                status: transaction.revocationDate == nil ? .active : .revoked,
                userID: userID
            )
            if shouldPrefer(candidate, over: resolved) {
                resolved = candidate
            }
        }

        return resolved
    }

    private func plan(for productID: String) -> OunjeMembershipPlan? {
        productIDsByPlan.first(where: { $0.value == productID })?.key
    }

    private func verifiedTransaction(from verificationResult: VerificationResult<StoreKit.Transaction>) throws -> StoreKit.Transaction {
        switch verificationResult {
        case .verified(let transaction):
            return transaction
        case .unverified:
            throw StoreBillingError.purchaseUnverified
        }
    }

    private func entitlement(from transaction: StoreKit.Transaction, plan: OunjeMembershipPlan, status: AppEntitlementStatus, userID: String?) -> AppUserEntitlement {
        AppUserEntitlement(
            userID: userID ?? String(transaction.appAccountToken?.uuidString ?? ""),
            tier: plan.tier,
            status: status,
            source: .appStore,
            productID: transaction.productID,
            transactionID: String(transaction.id),
            originalTransactionID: String(transaction.originalID),
            expiresAt: transaction.expirationDate,
            updatedAt: Date(),
            metadata: [
                "environment": String(describing: transaction.environment),
                "ownership_type": String(describing: transaction.ownershipType),
                "billing_cadence": plan.cadence.rawValue
            ]
        )
    }

    private func shouldPrefer(_ lhs: AppUserEntitlement, over rhs: AppUserEntitlement?) -> Bool {
        guard let rhs else { return true }
        let rank: [OunjePricingTier: Int] = [
            .free: 0,
            .plus: 1,
            .autopilot: 2,
            .foundingLifetime: 3,
        ]
        let lhsRank = rank[lhs.effectiveTier] ?? 0
        let rhsRank = rank[rhs.effectiveTier] ?? 0
        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }
        return (lhs.expiresAt ?? .distantPast) > (rhs.expiresAt ?? .distantPast)
    }
}

enum SupabaseEntitlementServiceError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Membership request could not be prepared."
        case .invalidResponse:
            return "Membership response was invalid."
        case .requestFailed(let message):
            return message
        }
    }
}

private struct EntitlementEnvelopeResponse: Decodable {
    let entitlement: AppUserEntitlement?
    let effectiveTier: OunjePricingTier

    enum CodingKeys: String, CodingKey {
        case entitlement
        case effectiveTier = "effectiveTier"
    }
}

final class SupabaseEntitlementService {
    static let shared = SupabaseEntitlementService()

    private init() {}

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardDateFormatter = ISO8601DateFormatter()

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = fractionalDateFormatter.date(from: rawValue)
                ?? standardDateFormatter.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(rawValue)"
            )
        }
        return decoder
    }

    func fetchCurrentEntitlement(userID: String, accessToken: String?) async throws -> AppUserEntitlement? {
        guard let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            throw SupabaseEntitlementServiceError.requestFailed("Membership session is missing.")
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                guard let url = URL(string: "\(baseURL)/v1/entitlements/current") else {
                    throw SupabaseEntitlementServiceError.invalidRequest
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 20
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(userID, forHTTPHeaderField: "x-user-id")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SupabaseEntitlementServiceError.invalidResponse
                }
                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                    let fallback = "Membership refresh failed (\(httpResponse.statusCode))."
                    throw SupabaseEntitlementServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                }
                let payload = try Self.makeDecoder().decode(EntitlementEnvelopeResponse.self, from: data)
                return payload.entitlement
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseEntitlementServiceError.invalidResponse
    }

    @discardableResult
    func syncCurrentEntitlement(snapshot: AppUserEntitlement, userID: String, accessToken: String?) async throws -> AppUserEntitlement? {
        guard let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else {
            throw SupabaseEntitlementServiceError.requestFailed("Membership session is missing.")
        }

        struct Payload: Encodable {
            let tier: String
            let status: String
            let source: String
            let productID: String?
            let transactionID: String?
            let originalTransactionID: String?
            let expiresAt: String?
            let metadata: [String: String]

            enum CodingKeys: String, CodingKey {
                case tier
                case status
                case source
                case productID = "product_id"
                case transactionID = "transaction_id"
                case originalTransactionID = "original_transaction_id"
                case expiresAt = "expires_at"
                case metadata
            }
        }

        var lastError: Error?
        for baseURL in OunjeDevelopmentServer.workerCandidateBaseURLs {
            do {
                guard let url = URL(string: "\(baseURL)/v1/entitlements/sync") else {
                    throw SupabaseEntitlementServiceError.invalidRequest
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue(userID, forHTTPHeaderField: "x-user-id")
                request.httpBody = try JSONEncoder().encode(
                    Payload(
                        tier: snapshot.tier.rawValue,
                        status: snapshot.status.rawValue,
                        source: snapshot.source.rawValue,
                        productID: snapshot.productID,
                        transactionID: snapshot.transactionID,
                        originalTransactionID: snapshot.originalTransactionID,
                        expiresAt: snapshot.expiresAt?.ISO8601Format(),
                        metadata: snapshot.metadata
                    )
                )
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SupabaseEntitlementServiceError.invalidResponse
                }
                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    let errorPayload = try? JSONDecoder().decode(SupabaseRestErrorResponse.self, from: data)
                    let fallback = "Membership sync failed (\(httpResponse.statusCode))."
                    throw SupabaseEntitlementServiceError.requestFailed(errorPayload?.message ?? errorPayload?.error ?? fallback)
                }
                let payload = try Self.makeDecoder().decode(EntitlementEnvelopeResponse.self, from: data)
                return payload.entitlement
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SupabaseEntitlementServiceError.invalidResponse
    }
}
