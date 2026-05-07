import StoreKit
import SwiftUI

@MainActor
final class ProPurchaseManager: ObservableObject {
    static let shared = ProPurchaseManager()

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var lastErrorMessage: String?

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
                    lastErrorMessage = "Purchase couldn’t be verified."
                    return false
                }
                let isProTransaction = transaction.productID == ProEntitlement.productID
                if isProTransaction {
                    setIsPro(true)
                }
                await transaction.finish()
                await refreshEntitlements()
                return isProTransaction

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
        } catch {
            if error is CancellationError { return }
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshEntitlements() async {
        var purchased = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == ProEntitlement.productID {
                purchased = true
                break
            }
        }
        setIsPro(purchased)
    }

    private func startListeningForTransactionUpdates() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result else { continue }
                guard transaction.productID == ProEntitlement.productID else { continue }
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }
}
