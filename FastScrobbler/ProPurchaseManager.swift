import StoreKit
import SwiftUI
import OSLog

@MainActor
final class ProPurchaseManager: ObservableObject {
    static let shared = ProPurchaseManager()

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var lastErrorMessage: String?

    private let logger = Logger(subsystem: "FastScrobbler", category: "ProPurchase")
    private var didStart = false
    private var updatesTask: Task<Void, Never>?

    private init() {
        self.isPro = ProEntitlement.isPro
    }

    deinit {
        updatesTask?.cancel()
    }

    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true

#if os(macOS)
        // Pro is always enabled on macOS; no StoreKit flow.
        setIsPro(true)
#else
        startListeningForTransactionUpdates()
        await refreshEntitlements()
        await loadProductIfNeeded()
#endif
    }

    @discardableResult
    func purchase() async -> Bool {
        lastErrorMessage = nil

#if os(macOS)
        setIsPro(true)
        return true
#else
        if product == nil {
            await loadProductIfNeeded()
        }
        guard let product else {
            lastErrorMessage = "Unable to load FastScrobbler Pro."
            return false
        }

        guard !isPurchasing else { return false }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    logger.warning("purchase verification failed for product \(product.id, privacy: .public)")
                    lastErrorMessage = "Purchase couldn’t be verified."
                    return false
                }
                let isProTransaction = transaction.productID == ProEntitlement.productID
                let isActiveProTransaction = isProTransaction && isActiveEntitlement(transaction)
                if isActiveProTransaction {
                    logger.info("verified Pro purchase for \(transaction.productID, privacy: .public)")
                    setIsPro(true)
                } else {
                    logger.warning("verified purchase did not match active Pro entitlement: productID=\(transaction.productID, privacy: .public), revoked=\(transaction.revocationDate != nil, privacy: .public), upgraded=\(transaction.isUpgraded, privacy: .public)")
                }
                await transaction.finish()
                await refreshEntitlements()
                return isActiveProTransaction

            case .userCancelled:
                return false

            case .pending:
                lastErrorMessage = "Purchase pending approval."
                return false

            @unknown default:
                return false
            }
        } catch {
            if error is CancellationError { return false }
            lastErrorMessage = error.localizedDescription
            return false
        }
#endif
    }

    func restorePurchases() async {
        lastErrorMessage = nil

#if os(macOS)
        setIsPro(true)
        return
#else
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            if error is CancellationError { return }
            lastErrorMessage = error.localizedDescription
        }
#endif
    }

    private func setIsPro(_ newValue: Bool) {
        if isPro != newValue {
            isPro = newValue
        }
        ProEntitlement.isPro = newValue
    }

    private func loadProductIfNeeded() async {
        guard product == nil else { return }
        do {
            let products = try await Product.products(for: [ProEntitlement.productID])
            product = products.first
            if let product {
                logger.info("loaded Pro product \(product.id, privacy: .public)")
            } else {
                logger.warning("Pro product \(ProEntitlement.productID, privacy: .public) not returned by App Store")
            }
        } catch {
            if error is CancellationError { return }
            logger.error("failed to load Pro product: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshEntitlements() async {
        var purchased = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == ProEntitlement.productID, isActiveEntitlement(transaction) {
                purchased = true
                break
            }
        }

        if !purchased, let transaction = await latestVerifiedProTransaction(), isActiveEntitlement(transaction) {
            logger.info("restored Pro from latest verified transaction for \(transaction.productID, privacy: .public)")
            purchased = true
        }

        logger.info("refreshed Pro entitlement: purchased=\(purchased, privacy: .public)")
        setIsPro(purchased)
    }

    private func startListeningForTransactionUpdates() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result else { continue }
                guard transaction.productID == ProEntitlement.productID else { continue }
                self.logger.info("received Pro transaction update for \(transaction.productID, privacy: .public)")
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }

    private func latestVerifiedProTransaction() async -> StoreKit.Transaction? {
        let latest = await StoreKit.Transaction.latest(for: ProEntitlement.productID)
        guard case .verified(let transaction) = latest else { return nil }
        return transaction
    }

    private func isActiveEntitlement(_ transaction: StoreKit.Transaction) -> Bool {
        guard transaction.revocationDate == nil else { return false }
        guard !transaction.isUpgraded else { return false }
        if let expirationDate = transaction.expirationDate {
            return expirationDate > Date()
        }
        return true
    }
}
