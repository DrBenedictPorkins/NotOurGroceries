import Foundation
import StoreKit

/// Buying a subscription, and keeping the server's idea of it up to date.
///
/// Apple sells to an Apple ID; this app is entitled per household. Those are
/// different things, and the join between them is `redeemSubscription`: the
/// phone hands the server a signed transaction, the server verifies Apple's
/// signature and marks *the household* subscribed. Nothing here decides whether
/// a feature is allowed — `AllowanceService` and the Lambdas already do that,
/// and a client that could grant itself entitlement would not be a limit.
///
/// There is no server-to-server notification and there will not be one. Expiry
/// and refunds are both noticed the same way: `subscriptionExpiresAt` passes and
/// the server reads the household as free again. See MONETIZATION.qmd.
@MainActor
final class StoreKitService: ObservableObject {
    static let shared = StoreKitService()

    /// The two SKUs, in one place.
    ///
    /// These must match the product identifiers in App Store Connect exactly.
    /// Until that subscription group exists they resolve only against the local
    /// `Products.storekit` configuration, which is how the whole flow is
    /// testable before any paperwork is signed.
    enum ProductID {
        static let monthly = "com.byteclub.grocery.sub.monthly"
        static let yearly = "com.byteclub.grocery.sub.yearly"
        static var all: [String] { [monthly, yearly] }
    }

    /// `StoreKit.Product`, spelled out everywhere in this file. The app has its
    /// own `Product` — the grocery catalogue — and the unqualified name resolves
    /// to that one.
    @Published private(set) var products: [StoreKit.Product] = []
    @Published private(set) var isLoadingProducts = false

    /// Set while a purchase is in flight, so the paywall can disable itself
    /// rather than let somebody tap Subscribe twice.
    @Published private(set) var purchaseInFlight = false

    /// Surfaced by the paywall. Never a raw StoreKit error — those say things
    /// like "The operation couldn't be completed", which tells a person nothing.
    @Published var purchaseError: String?

    /// True once a purchase or restore has been handed to the server and
    /// accepted, so the paywall can dismiss itself on the real outcome rather
    /// than on the App Store sheet closing.
    @Published private(set) var didEntitleHousehold = false

    private var updatesTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Starts listening for transactions that arrive without a purchase in this
    /// process: an Ask-to-Buy approval, a renewal, a purchase made on another
    /// device. Without this those never reach the server and the household stays
    /// free having paid.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handle(update, finishing: true)
            }
        }
    }

    func loadProducts() async {
        guard products.isEmpty, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await StoreKit.Product.products(for: ProductID.all)
            // Cheapest first, so the monthly price is the one read first and the
            // yearly reads as the saving rather than the shock.
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            purchaseError = "Couldn't load the subscription options. Try again."
            print("StoreKit: product load failed — \(error)")
        }
    }

    // MARK: - Buying

    func purchase(_ product: StoreKit.Product) async {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        purchaseError = nil

        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification, finishing: true)
            case .userCancelled:
                break
            case .pending:
                // Ask-to-Buy, or a payment method needing action. It is not a
                // failure and it is not done; the `Transaction.updates` listener
                // is what will pick it up, possibly days later.
                purchaseError = "That purchase is waiting for approval. It'll unlock as soon as it goes through."
            @unknown default:
                purchaseError = "Something unexpected happened. Try again."
            }
        } catch {
            purchaseError = "Couldn't complete the purchase. Try again."
            print("StoreKit: purchase failed — \(error)")
        }
    }

    /// Required by App Review, and genuinely needed: a household member who
    /// reinstalls, or the payer on a second device, has a valid subscription and
    /// no local record of it.
    func restore() async {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        purchaseError = nil

        // `AppStore.sync()` forces a real receipt refresh and will ask for the
        // Apple ID password. Only ever from an explicit Restore tap, never on
        // launch — a password prompt nobody asked for reads as a scam.
        try? await AppStore.sync()

        let entitled = await syncEntitlements()
        if !entitled {
            purchaseError = "No subscription found on this Apple ID."
        }
    }

    /// Re-tells the server what Apple currently says. Called on launch and when
    /// the allowances page opens.
    ///
    /// Cheap and silent: `currentEntitlements` is local, and the server call
    /// only happens when there is actually something to report.
    @discardableResult
    func syncEntitlements() async -> Bool {
        var found = false
        for await entitlement in Transaction.currentEntitlements {
            guard ProductID.all.contains(entitlementProductID(entitlement)) else { continue }
            found = true
            // Not finished here: these have been finished already, and calling
            // `finish()` on a renewal we merely observed would be wrong.
            await handle(entitlement, finishing: false)
        }
        return found
    }

    // MARK: - Redeeming against the household

    private func handle(_ result: VerificationResult<Transaction>, finishing: Bool) async {
        guard case .verified(let transaction) = result else {
            // Apple could not vouch for it. Say nothing to the server; an
            // unverified transaction is exactly what a tampered one looks like.
            print("StoreKit: unverified transaction, ignoring")
            return
        }

        let redeemed = await AllowanceService.shared.redeemSubscription(
            signedTransaction: signedPayload(for: result)
        )

        if redeemed {
            didEntitleHousehold = true
        } else {
            purchaseError = "Your purchase went through, but we couldn't reach the server to unlock it. It'll unlock next time you open the app."
        }

        if finishing {
            await transaction.finish()
        }
    }

    /// The signed JWS exactly as Apple produced it. The server verifies this
    /// signature — anything the client decoded and re-encoded would be a claim,
    /// not a proof.
    private func signedPayload(for result: VerificationResult<Transaction>) -> String {
        result.jwsRepresentation
    }

    private func entitlementProductID(_ result: VerificationResult<Transaction>) -> String {
        switch result {
        case .verified(let transaction): return transaction.productID
        case .unverified(let transaction, _): return transaction.productID
        }
    }
}

extension StoreKit.Product {
    /// "$1.99 / month". Built from the product rather than hardcoded, so a price
    /// change in App Store Connect, or a different storefront's currency, is
    /// reflected without a build.
    var priceWithPeriod: String {
        guard let period = subscription?.subscriptionPeriod else { return displayPrice }
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 1 ? "day" : "\(period.value) days"
        case .week: unit = period.value == 1 ? "week" : "\(period.value) weeks"
        case .month: unit = period.value == 1 ? "month" : "\(period.value) months"
        case .year: unit = period.value == 1 ? "year" : "\(period.value) years"
        @unknown default: return displayPrice
        }
        return "\(displayPrice) / \(unit)"
    }
}
