import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import AccountContext

/// ice9's PaymentMethodUI: there are no saved cards and no card entry (#181).
/// Upstream's only caller, the profile's payment-method screen, is never
/// opened; these keep it compiling and go away if it ever is.
public final class AddPaymentMethodSheetScreen: ViewController {
    public init(context: AccountContext, action: @escaping () -> Void) {
        super.init(navigationBarPresentationData: nil)
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Queue.mainQueue().async { [weak self] in
            self?.dismiss(animated: false)
        }
    }
}

public final class PaymentCardEntryScreen: ViewController {
    public struct EnteredCardInfo: Equatable {
        public var id: UInt64
        public var number: String
        public var name: String
        public var expiration: String
        public var code: String
    }

    public init(context: AccountContext, completion: @escaping (EnteredCardInfo) -> Void) {
        super.init(navigationBarPresentationData: nil)
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Queue.mainQueue().async { [weak self] in
            self?.dismiss(animated: false)
        }
    }
}

public func paymentMethodListScreen(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, items: [PaymentCardEntryScreen.EnteredCardInfo]) -> ViewController {
    return AddPaymentMethodSheetScreen(context: context, action: {})
}
