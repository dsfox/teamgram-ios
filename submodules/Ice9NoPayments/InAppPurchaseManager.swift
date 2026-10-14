import Foundation
import SwiftSignalKit
import TelegramCore

/// ice9's InAppPurchaseManager: the App Store is never asked (#181). Upstream's
/// added a purchase queue observer and requested Telegram's 35 Premium and
/// Stars products at every launch and on the sign-in screen. This keeps the
/// API its callers use and sells nothing: there are no products, so nothing
/// can be bought, and StoreKit is not imported.
public final class InAppPurchaseManager: NSObject {
    public final class Product: Equatable {
        init() {
        }

        public var id: String {
            return ""
        }

        public var isSubscription: Bool {
            return false
        }

        public var price: String {
            return ""
        }

        public func pricePerMonth(_ monthsCount: Int) -> String {
            return ""
        }

        public func defaultPrice(_ value: NSDecimalNumber, monthsCount: Int) -> String {
            return ""
        }

        public func multipliedPrice(count: Int) -> String {
            return ""
        }

        public var priceValue: NSDecimalNumber {
            return NSDecimalNumber.zero
        }

        public var priceCurrencyAndAmount: (currency: String, amount: Int64) {
            return ("", 0)
        }

        public static func ==(lhs: Product, rhs: Product) -> Bool {
            return lhs === rhs
        }
    }

    public enum PurchaseState {
        case waiting
        case pending
        case purchased(transactionId: String)
    }

    public enum PurchaseError {
        case generic
        case cancelled
        case network
        case notAllowed
        case cantMakePayments
        case assignFailed
        case tryLater
    }

    public enum RestoreState {
        case succeed(Bool)
        case failed
    }

    public struct ReceiptPurchase: Equatable {
        public let productId: String
        public let transactionId: String
        public let expirationDate: Date
    }

    public init(engine: SomeTelegramEngine) {
        super.init()
        Logger.shared.log("InAppPurchaseManager", "ice9: nothing is sold here; the App Store is not asked")
    }

    public var availableProducts: Signal<[Product], NoError> {
        return .single([])
    }

    public func restorePurchases(completion: @escaping (RestoreState) -> Void) {
        Queue.mainQueue().async {
            completion(.succeed(true))
        }
    }

    public func buyProduct(_ product: Product, quantity: Int32 = 1, purpose: AppStoreTransactionPurpose, reportPending: Bool = false) -> Signal<PurchaseState, PurchaseError> {
        return .fail(.cantMakePayments)
    }

    public func getReceiptPurchases() -> [ReceiptPurchase] {
        return []
    }
}
