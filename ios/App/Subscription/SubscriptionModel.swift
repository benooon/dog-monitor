import DogMonitorCore
import Foundation
import Observation
import StoreKit

/// Premium for the owner's household. StoreKit 2 makes the purchase; the backend verifies each
/// signed transaction and owns the plan, so every screen reads `status` from the server.
@MainActor
@Observable
final class SubscriptionModel {
    /// Whether the App Store returned the Premium products, so the store can show real prices.
    enum StoreState: Equatable {
        case loading
        case ready
        /// No products came back (offline, App Store Connect not set up, or no StoreKit file).
        case unavailable
    }

    /// Asks the App Store how many of the given product ids it sells.
    typealias ProductLoader = @Sendable ([String]) async throws -> Int

    private(set) var status: SubscriptionDTO?
    private(set) var storeState: StoreState = .loading
    private(set) var isRestoring = false
    var errorMessage: String?

    /// Ties purchases to the household (`appAccountToken`), so one subscription unlocks one household.
    let householdId: UUID
    private let api: DogMonitorAPI
    private let productLoader: ProductLoader
    private var updatesTask: Task<Void, Never>?

    init(
        api: DogMonitorAPI,
        householdId: UUID,
        productLoader: @escaping ProductLoader = { try await Product.products(for: $0).count }
    ) {
        self.api = api
        self.householdId = householdId
        self.productLoader = productLoader
    }

    /// Loads the products before showing the store. `SubscriptionStoreView` spins forever when
    /// none come back, so the view shows "not available" with Try again instead.
    func loadProducts() async {
        storeState = .loading
        let count = (try? await productLoader(SubscriptionProducts.all)) ?? 0
        storeState = count > 0 ? .ready : .unavailable
    }

    /// Listens for renewals and purchases made elsewhere, and reports what the Apple ID already owns.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.report(update, finish: true)
            }
        }
        Task { await syncEntitlements() }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    func refresh() async {
        if let status = try? await api.subscription() {
            self.status = status
        }
    }

    /// Called by the store view after a purchase.
    func handlePurchase(_ result: Result<Product.PurchaseResult, any Error>) async {
        switch result {
        case .success(.success(let verification)):
            await report(verification, finish: true)
        case .success:
            break // Waiting for approval (Ask to Buy) or cancelled.
        case .failure:
            errorMessage = String(localized: "The purchase didn't go through. Please try again.")
        }
    }

    /// "Restore purchases": asks the App Store for this Apple ID's purchases, then reports them.
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
        } catch {
            // Cancelled sign-in or offline: report whatever StoreKit already knows.
        }
        await syncEntitlements()
    }

    private func syncEntitlements() async {
        for await entitlement in Transaction.currentEntitlements {
            await report(entitlement, finish: false)
        }
        await refresh()
    }

    private func report(_ verification: VerificationResult<Transaction>, finish: Bool) async {
        // Unverified transactions are ignored here; the server would reject them anyway.
        guard case .verified(let transaction) = verification,
              SubscriptionProducts.isPremium(transaction.productID) else { return }
        do {
            status = try await api.reportAppleTransaction(verification.jwsRepresentation)
            errorMessage = nil
            if finish { await transaction.finish() }
        } catch let error as APIError where error.code == "subscription_in_use" {
            errorMessage = String(localized: "This subscription already unlocks another household.")
            if finish { await transaction.finish() }
        } catch {
            // Left unfinished: StoreKit delivers it again and the next launch reports it.
            if finish {
                errorMessage = String(localized: "Couldn't confirm Premium. We'll try again the next time you open the app.")
            }
        }
    }
}
